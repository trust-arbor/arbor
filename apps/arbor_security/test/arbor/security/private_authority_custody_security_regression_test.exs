defmodule Arbor.Security.PrivateAuthorityCustodySecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "SSEC-002,SSEC-013,SSEC-014"

  @moduletag :fast

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.ApprovalReceiptBroker
  alias Arbor.Security.AuthorityStore
  alias Arbor.Security.DeliveryReceiptBroker
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.MasterKeyAccessOwner
  alias Arbor.Security.SigningAuthorityBroker
  alias Arbor.Security.SigningAuthorityBroker.KeyHolder
  alias Arbor.Security.SigningAuthorityStateOwner
  alias Arbor.Security.SystemAuthority

  @tag spec: "SSEC-002,SSEC-013,SSEC-014"
  test "security regression: root and signing authority callback state contain no live bearer" do
    {:ok, cap} =
      Capability.new(
        resource_uri: "arbor://fs/read/private-custody-regression",
        principal_id: "agent_private_custody_regression"
      )

    assert {:ok, signed_cap} = SystemAuthority.sign_capability_for_test(cap)
    assert :ok = SystemAuthority.verify_capability_signature(signed_cap)

    for owner <- [SystemAuthority, SigningAuthorityBroker, SigningAuthorityStateOwner] do
      assert %{private_state: custody} = :sys.get_state(owner)
      assert is_reference(custody)
      assert Map.keys(:sys.get_state(owner)) == [:private_state]
    end

    registry_state = :sys.get_state(Registry)
    refute Map.has_key?(registry_state, :registration_token)
    refute Map.has_key?(registry_state, :system_authority_pid)
    refute Map.has_key?(registry_state, :scheduler_identity_pid)
    refute Map.has_key?(registry_state, :trust_capability_grant_owner_pid)
    assert %{private_state: _custody} = registry_state.registration_custody

    public_key = SystemAuthority.public_key()
    assert {:ok, ^public_key} = Registry.lookup(SystemAuthority.agent_id())
  end

  test "security regression: approval and delivery receipt bearers never enter callback state" do
    digest = String.duplicate("a", 64)

    assert {:ok, approval} =
             ApprovalReceiptBroker.issue_for_test(
               "human_private_custody",
               "arbor://approval/private_custody",
               :approve,
               digest,
               "request-private-custody"
             )

    approval_state = :sys.get_state(ApprovalReceiptBroker)
    assert Map.keys(approval_state) == [:private_state]
    refute contains_term?(approval_state, approval.token)

    assert :ok =
             ApprovalReceiptBroker.consume(
               approval,
               "human_private_custody",
               "arbor://approval/private_custody",
               :approve,
               digest
             )

    name = :"delivery_private_custody_#{System.unique_integer([:positive])}"
    {:ok, broker} = DeliveryReceiptBroker.start_link(name: name)

    on_exit(fn -> if Process.alive?(broker), do: GenServer.stop(broker) end)

    assert {:ok, receipt} =
             DeliveryReceiptBroker.issue(
               name,
               "human_private_custody",
               "arbor://delivery/private-custody",
               :chat
             )

    delivery_state = :sys.get_state(broker)
    assert Map.keys(delivery_state) == [:private_state]
    refute contains_term?(delivery_state, receipt.token)

    assert {:ok, "human_private_custody"} =
             DeliveryReceiptBroker.consume(
               name,
               receipt.token,
               "arbor://delivery/private-custody",
               :chat
             )
  end

  test "security regression: key holder hides plaintext and rejects transferred replacement custody" do
    key = :crypto.strong_rand_bytes(32)
    {:ok, holder, transfer_ref} = KeyHolder.start(key, self(), self(), 5_000)

    assert %{private_state: custody} = :sys.get_state(holder)
    assert is_reference(custody)
    refute contains_term?(:sys.get_state(holder), key)
    assert {:ok, ^key} = KeyHolder.take(holder, transfer_ref)

    replacement_key = :crypto.strong_rand_bytes(32)
    {:ok, attacked_holder, attacked_ref} = KeyHolder.start(key, self(), self(), 5_000)
    holder_monitor = Process.monitor(attacked_holder)
    fake_authenticated_calls = Arbor.Common.new_authenticated_call_custody()
    owner_monitor = Process.monitor(self())
    broker_monitor = Process.monitor(self())
    expiry_timer = Process.send_after(self(), :discard_fake_expiry, 60_000)
    hostile = :ets.new(__MODULE__, [:set, :private])

    true =
      :ets.insert(
        hostile,
        {:signing_key_holder_v1,
         %{
           authenticated_calls: fake_authenticated_calls,
           broker_monitor: broker_monitor,
           broker_pid: self(),
           expiry_timer: expiry_timer,
           owner_monitor: owner_monitor,
           owner_pid: self(),
           private_key: replacement_key,
           transfer_ref: attacked_ref
         }}
      )

    true = :ets.give_away(hostile, attacked_holder, :hostile_key_holder_state)
    assert :ets.info(hostile, :owner) == attacked_holder
    :sys.replace_state(attacked_holder, fn _state -> %{private_state: hostile} end)

    refute match?({:ok, _key}, KeyHolder.take(attacked_holder, attacked_ref))
    assert_receive {:DOWN, ^holder_monitor, :process, ^attacked_holder, _reason}, 2_000
    Process.cancel_timer(expiry_timer)
    Process.demonitor(owner_monitor, [:flush])
    Process.demonitor(broker_monitor, [:flush])
  end

  test "security regression: master-key grants and AuthorityStore backend opts stay private" do
    master_state = :sys.get_state(MasterKeyAccessOwner)
    assert Map.keys(master_state) == [:private_state]
    refute Map.has_key?(master_state, :grants)

    store = Process.whereis(:arbor_security_capabilities)
    store_state = :sys.get_state(store)
    refute Map.has_key?(store_state, :backend_opts)
    assert %{private_state: _custody} = store_state.backend_custody

    assert AuthorityStore.durability_class(name: :arbor_security_capabilities) in [
             :process_lifetime,
             :application_restart,
             :node_restart
           ]
  end

  defp contains_term?(term, needle) when term === needle, do: true

  defp contains_term?(term, needle) when is_map(term) do
    Enum.any?(term, fn {key, value} ->
      contains_term?(key, needle) or contains_term?(value, needle)
    end)
  end

  defp contains_term?(term, needle) when is_list(term),
    do: Enum.any?(term, &contains_term?(&1, needle))

  defp contains_term?(term, needle) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.any?(&contains_term?(&1, needle))

  defp contains_term?(_term, _needle), do: false
end
