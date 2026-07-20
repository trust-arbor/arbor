defmodule Arbor.Security.DistributedSignalSubscriptionSecurityTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Security
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Identity.NonceCache
  alias Arbor.Security.Identity.Registry
  alias Arbor.Signals
  alias Arbor.Signals.Bus

  @expected_patterns %{
    nonce_cache: ["security.nonce_seen"],
    capability_store: [
      "security.capability_granted",
      "security.capability_revoked",
      "security.capabilities_revoked_all",
      "security.capabilities_cascade_revoked",
      "security.capabilities_scope_revoked"
    ],
    identity_registry: [
      "security.identity_registered",
      "security.identity_deregistered",
      "security.identity_suspended",
      "security.identity_resumed",
      "security.identity_revoked"
    ]
  }

  @stores [Registry, NonceCache, CapabilityStore]

  setup do
    original_authorizer = Application.get_env(:arbor_signals, :authorizer)
    original_allow_open = Application.get_env(:arbor_signals, :allow_open_authorizer)

    Application.put_env(
      :arbor_signals,
      :authorizer,
      Arbor.Signals.Adapters.CapabilityAuthorizer
    )

    Application.delete_env(:arbor_signals, :allow_open_authorizer)
    restart_security_stores()

    on_exit(fn ->
      restore_env(:authorizer, original_authorizer)
      restore_env(:allow_open_authorizer, original_allow_open)
    end)

    :ok
  end

  test "security regression: all stores establish exact subscriptions under CapabilityAuthorizer" do
    assert Arbor.Signals.Config.authorizer() == Arbor.Signals.Adapters.CapabilityAuthorizer
    assert {:error, :unauthorized} = Signals.subscribe("security.*", fn _signal -> :ok end)

    subscriptions = internal_subscriptions()
    assert length(subscriptions) == 11

    for {role, patterns} <- @expected_patterns do
      role_subscriptions =
        Enum.filter(subscriptions, &(&1.principal_id == {:internal_security_sync, role}))

      assert Enum.sort(Enum.map(role_subscriptions, & &1.pattern)) == Enum.sort(patterns)
    end

    for store <- @stores do
      sync = :sys.get_state(store).signal_sync
      listed_ids = MapSet.new(Enum.map(subscriptions, & &1.id))

      assert sync.bus_pid == Process.whereis(Bus)
      assert length(sync.subscription_ids) == expected_count(store)
      assert Enum.all?(sync.subscription_ids, &MapSet.member?(listed_ids, &1))
    end
  end

  test "security regression: Bus restart resubscribes all stores without stale IDs" do
    old_ids = internal_subscriptions() |> Enum.map(& &1.id) |> MapSet.new()
    old_bus_pid = Process.whereis(Bus)

    :ok = Supervisor.terminate_child(Arbor.Signals.Supervisor, Bus)
    {:ok, new_bus_pid} = Supervisor.restart_child(Arbor.Signals.Supervisor, Bus)

    refute new_bus_pid == old_bus_pid

    assert eventually(fn ->
             subscriptions = internal_subscriptions()
             new_ids = MapSet.new(Enum.map(subscriptions, & &1.id))

             length(subscriptions) == 11 and MapSet.disjoint?(old_ids, new_ids) and
               Enum.all?(@stores, fn store ->
                 sync = :sys.get_state(store).signal_sync
                 sync.bus_pid == new_bus_pid and sync.resubscribe_attempt == 0
               end)
           end)
  end

  test "security regression: restricted nonce signal reaches the public replay gate" do
    nonce = :crypto.strong_rand_bytes(16)

    assert :ok =
             Signals.emit(
               :security,
               :nonce_seen,
               %{
                 nonce_hex: Base.encode16(nonce, case: :lower),
                 expiry: System.system_time(:second) + 300,
                 origin_node: "peer@security-regression"
               },
               scope: :local
             )

    assert eventually(fn -> Map.has_key?(:sys.get_state(NonceCache).nonces, nonce) end)
    assert {:error, :replayed_nonce} = NonceCache.check_and_record(nonce, 300)
  end

  test "security regression: remote capability revocation reaches public authorization" do
    principal = "agent_remote_sync_#{System.unique_integer([:positive])}"
    resource = "arbor://test/security_sync/#{System.unique_integer([:positive])}"

    assert {:ok, capability} = Security.grant(principal: principal, resource: resource)

    assert {:ok, :authorized} =
             Security.authorize(principal, resource, nil, verify_identity: false)

    assert :ok =
             Signals.emit(
               :security,
               :capability_revoked,
               %{
                 capability_ids: [capability.id],
                 origin_node: "peer@security-regression"
               },
               scope: :local
             )

    assert eventually(fn ->
             Security.authorize(principal, resource, nil, verify_identity: false) ==
               {:error, :unauthorized}
           end)
  end

  test "security regression: remote identity suspension reaches public identity status" do
    assert {:ok, identity} =
             Security.generate_identity(name: "remote-sync-#{System.unique_integer([:positive])}")

    assert :ok = Security.register_identity(identity)
    assert {:ok, :active} = Security.identity_status(identity.agent_id)

    assert :ok =
             Signals.emit(
               :security,
               :identity_suspended,
               %{
                 agent_id: identity.agent_id,
                 origin_node: "peer@security-regression"
               },
               scope: :local
             )

    assert eventually(fn ->
             Security.identity_status(identity.agent_id) == {:ok, :suspended}
           end)
  end

  defp restart_security_stores do
    Enum.each(@stores, fn store ->
      :ok = Supervisor.terminate_child(Arbor.Security.Supervisor, store)

      case Supervisor.restart_child(Arbor.Security.Supervisor, store) do
        {:ok, _pid} -> :ok
        {:ok, _pid, _info} -> :ok
      end
    end)
  end

  defp internal_subscriptions do
    Enum.filter(Bus.list_subscriptions(), fn subscription ->
      match?({:internal_security_sync, _role}, subscription.principal_id)
    end)
  end

  defp expected_count(NonceCache), do: 1
  defp expected_count(CapabilityStore), do: 5
  defp expected_count(Registry), do: 5

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_signals, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_signals, key, value)
end
