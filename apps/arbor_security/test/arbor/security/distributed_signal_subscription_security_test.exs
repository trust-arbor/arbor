defmodule Arbor.Security.DistributedSignalSubscriptionSecurityTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Security
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Events
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
    original_distributed_signals = Application.get_env(:arbor_security, :distributed_signals)

    Arbor.Signals.Config.Testing.isolate_namespace()
    Arbor.Signals.Config.Testing.put(:authorizer, Arbor.Signals.Adapters.CapabilityAuthorizer)
    Arbor.Signals.Config.Testing.delete(:allow_open_authorizer)
    Application.put_env(:arbor_security, :distributed_signals, true)
    ensure_signals_children()
    restart_security_stores()

    on_exit(fn ->
      restore_security_env(:distributed_signals, original_distributed_signals)
      restart_security_stores()
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

  test "security regression: remote identity resume does NOT lift a local suspension" do
    # The asymmetry this whole gate rests on. Authority-REDUCING remote
    # mutations apply without an authenticated transport (the two tests
    # below/above); authority-RESTORING ones must not, or a forged signal
    # could un-suspend an identity this node deliberately suspended.
    #
    # :identity_resumed is the easy one to get wrong: it shares an apply
    # clause with :identity_suspended and :identity_revoked, so the split
    # has to happen before dispatch.
    assert {:ok, identity} =
             Security.generate_identity(name: "resume-gate-#{System.unique_integer([:positive])}")

    assert :ok = Security.register_identity(identity)
    assert :ok = Security.suspend_identity(identity.agent_id)
    assert {:ok, :suspended} = Security.identity_status(identity.agent_id)

    assert :ok =
             Signals.emit(
               :security,
               :identity_resumed,
               %{
                 agent_id: identity.agent_id,
                 origin_node: "peer@security-regression"
               },
               scope: :local
             )

    # Negative assertion, so give the signal a real chance to be applied
    # before concluding it was not.
    refute eventually(fn -> Security.identity_status(identity.agent_id) == {:ok, :active} end)
    assert {:ok, :suspended} = Security.identity_status(identity.agent_id)
  end

  test "security regression: local lifecycle audit echo is not a remote mutation" do
    assert {:ok, identity} =
             Security.generate_identity(name: "audit-echo-#{System.unique_integer([:positive])}")

    assert :ok = Security.register_identity(identity)
    assert {:ok, :active} = Security.identity_status(identity.agent_id)

    # Deterministically model a delayed local suspension audit. The telemetry
    # bridge must identify it as this node's observation, not as a remote
    # authority mutation.
    assert :ok = Events.record_identity_suspended(identity.agent_id, "delayed audit")

    refute eventually(fn ->
             Security.identity_status(identity.agent_id) == {:ok, :suspended}
           end)

    assert {:ok, :active} = Security.identity_status(identity.agent_id)
  end

  test "security regression: remote security mutations are admitted by authority direction" do
    # Pins the classification itself. If someone adds a new remote mutation
    # type, it must be placed deliberately on one side or the other — the
    # default (`false`) denies, which is the safe direction for a grant and
    # the WRONG one for a revocation, so an omission here is a silent hole.
    for reducing <- [
          :capability_revoked,
          :capabilities_revoked_all,
          :capabilities_cascade_revoked,
          :capabilities_scope_revoked,
          :identity_deregistered,
          :identity_suspended,
          :identity_revoked
        ] do
      assert Signals.admit_remote_security_mutation?(reducing),
             "#{reducing} removes authority and must apply without an authenticated transport"
    end

    for restoring <- [:capability_granted, :identity_registered, :identity_resumed] do
      refute Signals.admit_remote_security_mutation?(restoring),
             "#{restoring} adds authority and must stay gated"
    end

    refute Signals.admit_remote_security_mutation?(:not_a_security_mutation)
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

  defp ensure_signals_children do
    {:ok, _started} = Application.ensure_all_started(:arbor_kernel_runtime)

    for child <- [
          {Arbor.Signals.Store, []},
          {Arbor.Signals.TopicKeys, []},
          {Arbor.Signals.Channels, []},
          {Arbor.Signals.Bus, []},
          {Arbor.Signals.Relay, []}
        ] do
      case Supervisor.start_child(Arbor.Signals.Supervisor, child) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, :already_present} ->
          {module, _opts} = child
          :ok = Supervisor.delete_child(Arbor.Signals.Supervisor, module)
          {:ok, _pid} = Supervisor.start_child(Arbor.Signals.Supervisor, child)
      end
    end
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

  defp restore_security_env(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_security_env(key, value), do: Application.put_env(:arbor_security, key, value)
end
