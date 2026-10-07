defmodule Arbor.Security.SecuritySyncMailboxAuthenticationSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "KSEC-002,KSEC-010"

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Identity.NonceCache
  alias Arbor.Security.Identity.Registry
  alias Arbor.Signals

  @stores [Registry, NonceCache, CapabilityStore]

  setup do
    original_distributed_signals = Application.get_env(:arbor_security, :distributed_signals)

    Arbor.Signals.Config.Testing.isolate_namespace()
    Arbor.Signals.Config.Testing.put(:authorizer, Arbor.Signals.Adapters.CapabilityAuthorizer)
    Arbor.Signals.Config.Testing.delete(:allow_open_authorizer)
    Application.put_env(:arbor_security, :distributed_signals, true)

    assert :ok = Signals.restore_runtime_fixture()
    restart_security_stores()

    assert eventually(fn ->
             Enum.all?(@stores, fn store ->
               match?(%Arbor.Security.SignalSync{}, :sys.get_state(store).signal_sync)
             end)
           end)

    on_exit(fn ->
      restore_security_env(:distributed_signals, original_distributed_signals)
      :ok = Signals.restore_runtime_fixture()
      restart_security_stores()
    end)

    :ok
  end

  @tag spec: "KSEC-002,KSEC-010"
  test "security regression: visible state exposes no usable sync credential to raw mailbox callers" do
    principal = "agent_mailbox_victim_#{System.unique_integer([:positive])}"
    nonce = :crypto.strong_rand_bytes(16)

    assert {:ok, identity} = Security.generate_identity(name: "mailbox identity victim")
    assert :ok = Security.register_identity_fixture(identity)

    assert {:ok, capability} =
             Capability.new(
               principal_id: principal,
               resource_uri: "arbor://fs/read/mailbox-victim"
             )

    assert {:ok, :stored} = CapabilityStore.put_fixture(capability)

    on_exit(fn ->
      _ = CapabilityStore.revoke_fixture(capability.id)
      _ = Registry.deregister_fixture(identity.agent_id)
    end)

    forged_capability_signal =
      Signals.build_signal_fixture(
        :security,
        :capability_revoked,
        %{capability_id: capability.id, origin_node: "attacker@forged-mailbox"},
        scope: :local
      )

    forged_identity_signal =
      Signals.build_signal_fixture(
        :security,
        :identity_suspended,
        %{agent_id: identity.agent_id, origin_node: "attacker@forged-mailbox"},
        scope: :local
      )

    forged_nonce_signal =
      Signals.build_signal_fixture(
        :security,
        :nonce_seen,
        %{
          nonce_hex: Base.encode16(nonce, case: :lower),
          expiry: System.system_time(:second) + 300,
          origin_node: "attacker@forged-mailbox"
        },
        scope: :local
      )

    assert :ok = Signals.restore_runtime_fixture()
    bus_pid = Signals.bus_pid_fixture()
    assert is_pid(bus_pid)

    visible_states = [
      :sys.get_state(bus_pid),
      :sys.get_state(Process.whereis(CapabilityStore)),
      :sys.get_state(Process.whereis(Registry)),
      :sys.get_state(Process.whereis(NonceCache))
    ]

    refute Enum.any?(visible_states, &contains_map_key?(&1, :security_sync_delivery_ref))
    refute Enum.any?(visible_states, &contains_map_key?(&1, :delivery_refs))

    exposed_refs = visible_states |> Enum.flat_map(&visible_references/1) |> Enum.uniq()
    assert exposed_refs != []

    # The retired two-tuple shape and every reference available through an
    # ordinary state read must remain unusable as a delivery credential.
    send(CapabilityStore, {:signal_received, forged_capability_signal})
    send(Registry, {:signal_received, forged_identity_signal})
    send(NonceCache, {:signal_received, forged_nonce_signal})

    for exposed_ref <- exposed_refs do
      send(CapabilityStore, {:signal_received, exposed_ref, forged_capability_signal})
      send(Registry, {:signal_received, exposed_ref, forged_identity_signal})
      send(NonceCache, {:signal_received, exposed_ref, forged_nonce_signal})
    end

    # Calls from the same sender settle all preceding forged messages.
    assert {:ok, stored} = CapabilityStore.get(capability.id)
    assert {:ok, :active} = Registry.identity_status(identity.agent_id)
    _ = NonceCache.stats()

    assert stored.id == capability.id
    assert :ok = NonceCache.check_and_record(nonce, 300)

    legitimate_nonce = :crypto.strong_rand_bytes(16)

    legitimate_signal =
      Signals.build_signal_fixture(:security, :nonce_seen, %{
        nonce_hex: Base.encode16(legitimate_nonce, case: :lower),
        expiry: System.system_time(:second) + 300,
        origin_node: :peer@mailbox_authentication_regression
      })

    assert :ok =
             Signals.receive_relay_batch_fixture(
               [legitimate_signal],
               :peer@mailbox_authentication_regression
             )

    assert eventually(fn ->
             Map.has_key?(:sys.get_state(Process.whereis(NonceCache)).nonces, legitimate_nonce)
           end)

    assert {:error, :replayed_nonce} = NonceCache.check_and_record(legitimate_nonce, 300)
  end

  defp contains_map_key?(term, key) when is_map(term) do
    Map.has_key?(term, key) or
      Enum.any?(Map.to_list(term), fn {map_key, value} ->
        contains_map_key?(map_key, key) or contains_map_key?(value, key)
      end)
  end

  defp contains_map_key?(term, key) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.any?(&contains_map_key?(&1, key))

  defp contains_map_key?(term, key) when is_list(term),
    do: Enum.any?(term, &contains_map_key?(&1, key))

  defp contains_map_key?(term, key) when is_function(term) do
    case :erlang.fun_info(term, :env) do
      {:env, env} -> contains_map_key?(env, key)
      _other -> false
    end
  end

  defp contains_map_key?(_term, _key), do: false

  defp visible_references(term) when is_reference(term), do: [term]

  defp visible_references(term) when is_map(term) do
    Enum.flat_map(Map.to_list(term), fn {key, value} ->
      visible_references(key) ++ visible_references(value)
    end)
  end

  defp visible_references(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.flat_map(&visible_references/1)

  defp visible_references(term) when is_list(term),
    do: Enum.flat_map(term, &visible_references/1)

  defp visible_references(term) when is_function(term) do
    case :erlang.fun_info(term, :env) do
      {:env, env} -> visible_references(env)
      _other -> []
    end
  end

  defp visible_references(_term), do: []

  defp restart_security_stores do
    Enum.each(@stores, fn store ->
      :ok = Supervisor.terminate_child(Arbor.Security.Supervisor, store)

      case Supervisor.restart_child(Arbor.Security.Supervisor, store) do
        {:ok, _pid} -> :ok
        {:ok, _pid, _info} -> :ok
      end
    end)
  end

  defp restore_security_env(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_security_env(key, value), do: Application.put_env(:arbor_security, key, value)

  defp eventually(fun, attempts \\ 200)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end
end
