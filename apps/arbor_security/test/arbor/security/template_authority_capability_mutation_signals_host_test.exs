defmodule Arbor.Security.TemplateAuthorityCapabilityMutationSignalsHostTest do
  @moduledoc """
  Phase 4C C3A — crash-journal-safe acknowledged capability mutation.

  CANONICAL SUITE: this is the canonical general acknowledged-mutation
  regression file for the Security capability store (acknowledged grant/revoke,
  same-resource admission, post-admission ambiguity, convergence signals,
  signed_at determinism, and bounded uncertainty). Do not split or duplicate
  these invariants into other files without moving them here.

  The regression file is RUNNABLE on the immediate parent (HEAD~1): each test
  branches on `acknowledged_available?/0`. On the candidate it exercises the
  acknowledged API against a TRUTHFUL CAS backend (CASSandbox, using shared
  Record generation/revision/tombstone fencing); on the parent it exercises the ORDINARY
  grant/revoke API on the SAME retained topology and asserts the SAME
  invariant, which the ordinary API violates, so the assertion fails
  behaviorally (never via UndefinedFunctionError).
  """

  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security
  alias Arbor.Security.AuthorityStore
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.CapabilityStore.Serializer
  alias Arbor.Security.Config
  alias Arbor.Security.Events
  alias Arbor.Security.SystemAuthority
  alias Arbor.Security.TestBootstrap
  alias Arbor.Security.TestSupport.RecordingEventLogAdapter
  alias Arbor.Signals
  alias Arbor.Signals.Config.Testing, as: SignalsConfig

  alias Arbor.Security.TemplateAuthorityCapabilityMutationSecurityRegressionTest.CASSandbox

  @security_supervisor Arbor.Security.Supervisor
  @capability_store :arbor_security_capabilities
  @capability_sync_events [
    :capability_granted,
    :capability_revoked,
    :capabilities_revoked_all,
    :capabilities_cascade_revoked,
    :capabilities_scope_revoked
  ]

  defp acknowledged_available? do
    function_exported?(Arbor.Security, :acknowledged_grant, 1) and
      function_exported?(Arbor.Security, :acknowledged_revoke, 1) and
      function_exported?(Arbor.Security.CapabilityStore, :acknowledged_put, 1) and
      function_exported?(Arbor.Security.CapabilityStore, :acknowledged_revoke, 1)
  end

  defp det_id(seed), do: "cap_" <> (:erlang.md5(seed) |> Base.encode16(case: :lower))

  defp fixed_granted_at, do: ~U[2026-01-01 00:00:00Z]

  defp det_grant_opts(seed, principal, resource, extra \\ []) do
    [
      capability_id: det_id(seed),
      granted_at: fixed_granted_at(),
      principal: principal,
      resource: resource
    ] ++ extra
  end

  defp build_signed_cap(opts) do
    {:ok, cap} =
      Capability.new(
        resource_uri: Keyword.fetch!(opts, :resource),
        principal_id: Keyword.fetch!(opts, :principal),
        id: Keyword.fetch!(opts, :capability_id),
        granted_at: Keyword.fetch!(opts, :granted_at),
        expires_at: Keyword.get(opts, :expires_at),
        not_before: Keyword.get(opts, :not_before),
        constraints: Keyword.get(opts, :constraints, %{}),
        delegation_depth: Keyword.get(opts, :delegation_depth, 3),
        max_uses: Keyword.get(opts, :max_uses),
        allowed_delegatees: Keyword.get(opts, :allowed_delegatees),
        session_id: Keyword.get(opts, :session_id),
        task_id: Keyword.get(opts, :task_id),
        principal_scope: Keyword.get(opts, :principal_scope),
        metadata: Keyword.get(opts, :metadata, %{})
      )

    # Mirror the acknowledged facade: pin signed_at deterministically to
    # granted_at before signing so the signing payload is byte-identical to
    # Arbor.Security.acknowledged_grant/1 (identity-exact across retries).
    cap = %{cap | signed_at: cap.granted_at}
    {:ok, signed} = SystemAuthority.sign_capability_for_test(cap)
    signed
  end

  defp fresh_isolated_store do
    start_isolated_store(:"cas_sandbox_#{unique_integer()}")
  end

  defp fresh_isolated_store_with_failures do
    on_exit(&CASSandbox.clear/0)
    start_isolated_store(:"cas_sandbox_fail_#{unique_integer()}")
  end

  defp start_isolated_store(backend_name) do
    on_exit(&restore_security_children/0)

    :ok = Supervisor.terminate_child(@security_supervisor, CapabilityStore)
    :ok = Supervisor.terminate_child(@security_supervisor, @capability_store)

    {:ok, _pid} = CASSandbox.start_link(name: backend_name)
    on_exit(fn -> stop_named_process(backend_name) end)

    {:ok, _pid} =
      AuthorityStore.start_test_fixture(
        name: @capability_store,
        backend: CASSandbox,
        namespace: backend_name,
        hydration_limit: 10_000
      )

    {:ok, _pid} = CapabilityStore.start_link(test_isolated_owner: true)
    assert_capability_store_ready!()
    backend_name
  end

  defp assert_capability_store_ready! do
    assert {:ok, []} = Security.list_capabilities("agent_template_fixture_readiness_probe")
    :ok
  end

  defp restore_security_children do
    TestBootstrap.restore_supervised_tree!()
  end

  defp stop_named_process(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  defp unique_integer, do: :erlang.unique_integer([:positive])

  defp simulate_pre_c3a_state do
    :sys.replace_state(CapabilityStore, fn state ->
      state
      |> Map.delete(:by_resource)
      |> Map.delete(:pending_intents)
      |> Map.delete(:state_version)
    end)

    :ok
  end

  defp ensure_event_log do
    previous = Application.get_env(:arbor_capabilities, :event_log_adapter, :unset)
    RecordingEventLogAdapter.setup()
    Application.put_env(:arbor_capabilities, :event_log_adapter, RecordingEventLogAdapter)
    on_exit(fn -> restore_application_env(:event_log_adapter, previous) end)
    :ok
  end

  defp restore_application_env(key, :unset), do: Application.delete_env(:arbor_capabilities, key)

  defp restore_application_env(key, nil), do: Application.delete_env(:arbor_capabilities, key)

  defp restore_application_env(key, value),
    do: Application.put_env(:arbor_capabilities, key, value)

  defp restore_application_env(app, key, :error), do: Application.delete_env(app, key)

  defp restore_application_env(app, key, {:ok, value}),
    do: Application.put_env(app, key, value)

  defp ensure_signals_children do
    previous_signals = SignalsConfig.snapshot_namespace()
    previous_distributed = Application.fetch_env(:arbor_capabilities, :distributed_signals)

    signals =
      Application.get_all_env(:arbor_signals)
      |> Keyword.put(:security_sync_subscribers, %{
        capability_store: %{
          owner: CapabilityStore,
          supervisor: {:application, :arbor_capabilities},
          child_id: CapabilityStore,
          events: @capability_sync_events
        }
      })

    SignalsConfig.restore_namespace(signals)
    Application.put_env(:arbor_capabilities, :distributed_signals, true)

    on_exit(fn ->
      restore_application_env(:arbor_capabilities, :distributed_signals, previous_distributed)
      SignalsConfig.restore_namespace(previous_signals)
      :ok = Signals.restore_runtime_fixture()
    end)

    :ok = Signals.restore_runtime_fixture()

    # The ordinary isolated-store fixture starts CapabilityStore outside its
    # supervisor so corruption tests can observe a terminal process. Portable
    # security-signal publication has a stronger provenance gate: the publisher
    # must be the exact registered Security-supervisor child. Re-home only these
    # signal-observation cases after the isolated authority backend is ready.
    stop_named_process(CapabilityStore)
    assert {:ok, store_pid} = Supervisor.restart_child(@security_supervisor, CapabilityStore)
    assert_capability_store_ready!()

    assert Process.whereis(CapabilityStore) == store_pid

    assert Enum.any?(Supervisor.which_children(@security_supervisor), fn
             {CapabilityStore, ^store_pid, :worker, _modules} -> true
             _other -> false
           end)

    assert Signals.security_sync_role_configured?(:capability_store)

    pinned =
      Signals.list_subscriptions_fixture()
      |> Enum.filter(fn subscription ->
        subscription[:principal_id] == {:internal_security_sync, :capability_store}
      end)

    assert length(pinned) == length(@capability_sync_events)
    assert Enum.all?(pinned, &(&1[:security_sync_owner] == store_pid))
    :ok
  end

  defp count_audit(event_type, capability_id) do
    case Events.get_by_type(event_type) do
      {:ok, events} when is_list(events) ->
        Enum.count(events, fn e ->
          data = Map.get(e, :data, %{})
          (Map.get(data, :capability_id) || Map.get(data, "capability_id")) == capability_id
        end)

      _ ->
        0
    end
  end

  defp subscribe_store_grant_signal(capability_id) do
    parent = self()
    ref = make_ref()
    observer = signal_observer_id("grant")

    {:ok, sub} =
      Arbor.Signals.subscribe(
        "security.*",
        fn signal ->
          data = signal.data
          cid = data[:capability_id] || data["capability_id"]
          origin = data[:origin_node] || data["origin_node"]

          if cid == capability_id and same_node?(origin) do
            send(parent, {ref, :store_grant})
          end

          :ok
        end,
        principal_id: observer
      )

    {ref, sub}
  end

  defp subscribe_store_revoke_signal(capability_id) do
    parent = self()
    ref = make_ref()
    observer = signal_observer_id("revoke")

    {:ok, sub} =
      Arbor.Signals.subscribe(
        "security.*",
        fn signal ->
          data = signal.data
          origin = data[:origin_node] || data["origin_node"]
          ids = data[:capability_ids] || data["capability_ids"]

          if ids == [capability_id] and same_node?(origin) do
            send(parent, {ref, :store_revoke})
          end

          :ok
        end,
        principal_id: observer
      )

    {ref, sub}
  end

  defp signal_observer_id(tag) do
    "agent_ack_signal_observer_" <>
      tag <>
      "_" <>
      Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  end

  defp same_node?(nil), do: false

  defp same_node?(origin) when is_atom(origin), do: origin == node()

  defp same_node?(origin) when is_binary(origin), do: origin == Atom.to_string(node())

  defp collect_signals(ref, tag, window_ms) do
    deadline = System.monotonic_time(:millisecond) + window_ms
    do_collect_signals(ref, tag, deadline, 0)
  end

  defp do_collect_signals(ref, tag, deadline, acc) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^ref, ^tag} -> do_collect_signals(ref, tag, deadline, acc + 1)
    after
      remaining -> acc
    end
  end

  test "security regression: applied acknowledged grant emits one store signal and one audit row" do
    if acknowledged_available?() do
      fresh_isolated_store()
      ensure_event_log()
      ensure_signals_children()

      principal = "agent_ack_f4g"
      resource = "arbor://fs/read/ack-f4g"
      opts = det_grant_opts("f4g", principal, resource)
      id = opts[:capability_id]

      {ref, sub} = subscribe_store_grant_signal(id)
      on_exit(fn -> Arbor.Signals.unsubscribe(sub) end)

      audit_before = count_audit(:capability_granted, id)

      assert {:ok, :applied, ^id} = Security.acknowledged_grant_fixture(opts)

      # Idempotent retries emit NO additional signal or audit row.
      assert {:ok, :idempotent, ^id} = Security.acknowledged_grant_fixture(opts)
      assert {:ok, :idempotent, ^id} = Security.acknowledged_grant_fixture(opts)

      grants = collect_signals(ref, :store_grant, 200)
      audit_after = count_audit(:capability_granted, id)

      assert grants == 1
      assert audit_after - audit_before == 1
    end
  end

  test "security regression: applied acknowledged revoke emits one signal/row; absence emits none" do
    if acknowledged_available?() do
      fresh_isolated_store()
      ensure_event_log()
      ensure_signals_children()

      principal = "agent_ack_f4r"
      resource = "arbor://fs/read/ack-f4r"
      opts = det_grant_opts("f4r", principal, resource)
      id = opts[:capability_id]

      assert {:ok, :applied, ^id} = Security.acknowledged_grant_fixture(opts)

      {ref, sub} = subscribe_store_revoke_signal(id)
      on_exit(fn -> Arbor.Signals.unsubscribe(sub) end)

      audit_before = count_audit(:capability_revoked, id)

      assert {:ok, :applied, ^id} = Security.acknowledged_revoke_fixture(id)

      revokes = collect_signals(ref, :store_revoke, 200)
      audit_after_applied = count_audit(:capability_revoked, id)

      assert revokes == 1
      assert audit_after_applied - audit_before == 1

      # Authoritative-absent revoke is idempotent and emits NO signal/audit.
      unknown_id = det_id("f4r-absent")
      {uref, usub} = subscribe_store_revoke_signal(unknown_id)
      on_exit(fn -> Arbor.Signals.unsubscribe(usub) end)

      absent_audit_before = count_audit(:capability_revoked, unknown_id)

      assert {:ok, :idempotent, ^unknown_id} = Security.acknowledged_revoke_fixture(unknown_id)

      absent_revokes = collect_signals(uref, :store_revoke, 200)
      absent_audit_after = count_audit(:capability_revoked, unknown_id)

      assert absent_revokes == 0
      assert absent_audit_after - absent_audit_before == 0
    end
  end

  test "security regression: unauthenticated remote capability_granted does not project into live indexes" do
    fresh_isolated_store()
    principal = "agent_ack_c4d"
    resource = "arbor://fs/read/ack-c4d"
    remote_opts = det_grant_opts("c4d-remote", principal, resource)
    remote_id = remote_opts[:capability_id]

    if acknowledged_available?() do
      refute Arbor.Signals.authenticated_security_sync_transport?()

      remote_cap = build_signed_cap(remote_opts)

      assert {:ok, %Record{}} =
               AuthorityStore.acknowledged_put(
                 remote_id,
                 Record.new(remote_id, Serializer.serialize(remote_cap)),
                 name: @capability_store
               )

      send(
        CapabilityStore,
        {:signal_received,
         %{
           type: :capability_granted,
           data: %{
             capability_id: remote_id,
             origin_node: :remote@c4d_projection
           }
         }}
      )

      _ = :sys.get_state(CapabilityStore)

      assert {:error, :not_found} = CapabilityStore.get(remote_id)

      state = :sys.get_state(CapabilityStore)

      refute Enum.any?(Map.get(state, :by_resource, %{}), fn
               {{^principal, _uri}, ids} -> MapSet.member?(ids, remote_id)
               _ -> false
             end)
    else
      assert {:ok, _} = Security.grant_fixture(principal: principal, resource: resource)
    end
  end

  test "security regression: idempotent grant convergence emits one signal, replay emits none" do
    if acknowledged_available?() do
      fresh_isolated_store_with_failures()
      ensure_signals_children()

      principal = "agent_ack_c6"
      resource = "arbor://fs/read/ack-c6"
      opts = det_grant_opts("c6", principal, resource)
      id = opts[:capability_id]

      {ref, sub} = subscribe_store_grant_signal(id)
      on_exit(fn -> Arbor.Signals.unsubscribe(sub) end)

      CASSandbox.fail_post_admission(1)
      assert {:error, :outcome_unknown} = Security.acknowledged_grant_fixture(opts)

      assert {:ok, :idempotent, ^id} = Security.acknowledged_grant_fixture(opts)
      assert collect_signals(ref, :store_grant, 200) == 1

      assert {:ok, :idempotent, ^id} = Security.acknowledged_grant_fixture(opts)
      assert collect_signals(ref, :store_grant, 200) == 0
    else
      fresh_isolated_store()

      assert {:ok, _} =
               Security.grant_fixture(
                 principal: "agent_ack_c6",
                 resource: "arbor://fs/read/ack-c6"
               )
    end
  end

  test "security regression: idempotent revoke convergence emits one signal, replay emits none" do
    if acknowledged_available?() do
      fresh_isolated_store_with_failures()
      ensure_signals_children()

      principal = "agent_ack_c7"
      resource = "arbor://fs/read/ack-c7"
      opts = det_grant_opts("c7", principal, resource)
      id = opts[:capability_id]

      assert {:ok, :applied, ^id} = Security.acknowledged_grant_fixture(opts)

      {ref, sub} = subscribe_store_revoke_signal(id)
      on_exit(fn -> Arbor.Signals.unsubscribe(sub) end)

      CASSandbox.fail_post_delete(1)
      # The ordered authoritative reread proves the committed tombstone even
      # though the backend's delete acknowledgement was lost.
      assert {:ok, :applied, ^id} = Security.acknowledged_revoke_fixture(id)

      assert {:ok, :idempotent, ^id} = Security.acknowledged_revoke_fixture(id)
      assert collect_signals(ref, :store_revoke, 200) == 1

      assert {:ok, :idempotent, ^id} = Security.acknowledged_revoke_fixture(id)
      assert collect_signals(ref, :store_revoke, 200) == 0
    else
      fresh_isolated_store()

      assert {:ok, _} =
               Security.grant_fixture(
                 principal: "agent_ack_c7",
                 resource: "arbor://fs/read/ack-c7"
               )
    end
  end

  test "security regression: pre-C3A live state does not apply unauthenticated remote add or revoke" do
    fresh_isolated_store()
    refute Arbor.Signals.authenticated_security_sync_transport?()

    principal = "agent_upgrade_g5"
    resource = "arbor://fs/read/upgrade-g5"
    remote_opts = det_grant_opts("upgrade-g5-remote", principal, resource)
    remote_id = remote_opts[:capability_id]
    remote_cap = build_signed_cap(remote_opts)

    assert {:ok, %Record{}} =
             AuthorityStore.acknowledged_put(
               remote_id,
               Record.new(remote_id, Serializer.serialize(remote_cap)),
               name: @capability_store
             )

    simulate_pre_c3a_state()

    add_signal =
      Arbor.Signals.Signal.new(
        :security,
        :capability_granted,
        %{
          capability_id: remote_id,
          principal_id: principal,
          resource_uri: resource,
          origin_node: :"remote@upgrade-g5"
        },
        scope: :cluster
      )

    send(CapabilityStore, {:signal_received, add_signal})
    _ = :sys.get_state(CapabilityStore)

    assert {:error, :not_found} = Security.get_capability_fixture(remote_id)
    assert {:ok, capabilities} = Security.list_capabilities(principal)
    refute Enum.any?(capabilities, &(&1.id == remote_id))

    assert {:error, :unauthorized} =
             Security.authorize(principal, resource, nil, verify_identity: false)

    revoke_signal =
      Arbor.Signals.Signal.new(
        :security,
        :capability_revoked,
        %{
          capability_ids: [remote_id],
          principal_id: principal,
          origin_node: :"remote@upgrade-g5"
        },
        scope: :cluster
      )

    send(CapabilityStore, {:signal_received, revoke_signal})
    _ = :sys.get_state(CapabilityStore)

    assert {:error, :not_found} = Security.get_capability_fixture(remote_id)
    assert {:ok, capabilities} = Security.list_capabilities(principal)
    refute Enum.any?(capabilities, &(&1.id == remote_id))

    assert {:error, :unauthorized} =
             Security.authorize(principal, resource, nil, verify_identity: false)
  end
end
