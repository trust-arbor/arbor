defmodule Arbor.Agent.Orchestration.TaskControlCrashReplaySecurityRegressionTest do
  @moduledoc """
  Crash-point security regressions for task-control recovery:

  1. Durable recovery markers survive TaskStore death and startup reconciliation
     revokes task-scoped authority via Security.revoke_by_task/1 without TTL.
  2. Activation with a non-nil task-control lease is rejected until the
     reservation has a backend-acknowledged marker (marker-before-lease gate).

  Immediate parent 6ec5933b lacks the marker-before-lease gate — the second
  test fails behaviorally there and passes on the candidate.
  """
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Agent.Orchestration.{TaskControlLease, TaskControlRecoveryMemory, TaskStore}

  defmodule TrackingSecurity do
    @moduledoc false
    @table :task_control_crash_replay_security

    def ensure! do
      case :ets.whereis(@table) do
        :undefined -> _ = :ets.new(@table, [:named_table, :public, :set])
        _ -> :ok
      end

      :ok
    end

    def reset! do
      ensure!()
      :ets.insert(@table, {:revokes_by_task, []})
      :ets.insert(@table, {:caps, %{}})
      :ets.insert(@table, {:listed_principals, []})
      :ok
    end

    def grant(opts) do
      ensure!()
      task_id = opts[:task_id]
      kind = get_in(opts, [:metadata, :kind]) || "k"
      id = "cap_#{kind}_#{System.unique_integer([:positive])}"

      caps =
        case :ets.lookup(@table, :caps) do
          [{:caps, map}] -> map
          _ -> %{}
        end

      task_caps = Map.get(caps, task_id, [])
      record = %{id: id, resource_uri: opts[:resource], task_id: task_id}
      :ets.insert(@table, {:caps, Map.put(caps, task_id, [record | task_caps])})
      {:ok, record}
    end

    def revoke(id) do
      ensure!()

      caps =
        case :ets.lookup(@table, :caps) do
          [{:caps, map}] ->
            Enum.reduce(map, %{}, fn {tid, records}, acc ->
              Map.put(
                acc,
                tid,
                Enum.reject(records, fn
                  %{id: ^id} -> true
                  ^id -> true
                  _ -> false
                end)
              )
            end)

          _ ->
            %{}
        end

      :ets.insert(@table, {:caps, caps})
      :ok
    end

    def revoke_by_task(task_id) do
      ensure!()

      list =
        case :ets.lookup(@table, :revokes_by_task) do
          [{:revokes_by_task, l}] -> l
          _ -> []
        end

      :ets.insert(@table, {:revokes_by_task, list ++ [task_id]})

      caps =
        case :ets.lookup(@table, :caps) do
          [{:caps, map}] -> map
          _ -> %{}
        end

      ids = Map.get(caps, task_id, [])
      :ets.insert(@table, {:caps, Map.put(caps, task_id, [])})
      {:ok, length(ids)}
    end

    def caps_for(task_id) do
      ensure!()

      case :ets.lookup(@table, :caps) do
        [{:caps, map}] ->
          map
          |> Map.get(task_id, [])
          |> Enum.map(fn
            %{id: id} -> id
            id when is_binary(id) -> id
          end)

        _ ->
          []
      end
    end

    def list_capabilities(principal, opts \\ []) do
      ensure!()

      listed =
        case :ets.lookup(@table, :listed_principals) do
          [{:listed_principals, l}] -> l
          _ -> []
        end

      :ets.insert(@table, {:listed_principals, listed ++ [principal]})
      task_id = Keyword.get(opts, :task_id)

      records =
        case :ets.lookup(@table, :caps) do
          [{:caps, map}] -> Map.get(map, task_id, [])
          _ -> []
        end

      {:ok, records}
    end

    def listed_principals do
      ensure!()

      case :ets.lookup(@table, :listed_principals) do
        [{:listed_principals, l}] -> l
        _ -> []
      end
    end

    def revokes_by_task do
      ensure!()

      case :ets.lookup(@table, :revokes_by_task) do
        [{:revokes_by_task, l}] -> l
        _ -> []
      end
    end
  end

  defmodule HangRunner do
    @moduledoc false
    def run(_, _, _), do: Process.sleep(60_000)
  end

  defmodule HangRecover do
    @moduledoc false
    def run(_, _, _), do: Process.sleep(60_000)
    def recover_task(_, _), do: Process.sleep(60_000)

    def probe_recovery(agent_id, context) do
      {:ok,
       {:recoverable,
        Arbor.Agent.Orchestration.TaskControlCrashReplaySecurityRegressionTest.probe_projection(
          agent_id,
          context,
          "a"
        )}}
    end
  end

  defmodule RecoverSuccess do
    @moduledoc false
    def run(_, _, _), do: {:ok, %{"status" => "success"}}

    def recover_task(_agent_id, _context) do
      {:ok, %{"status" => "success", "artifacts" => %{}}}
    end

    def probe_recovery(agent_id, context) do
      {:ok,
       {:recoverable,
        Arbor.Agent.Orchestration.TaskControlCrashReplaySecurityRegressionTest.probe_projection(
          agent_id,
          context,
          "b"
        )}}
    end
  end

  defmodule RecoverCancel do
    @moduledoc false
    def run(_, _, _), do: Process.sleep(60_000)
    def recover_task(_, _), do: {:error, :cancelled}
    def finalize_terminal_task(_agent_id, _envelope, _controls, _context), do: :ok

    def probe_recovery(agent_id, context) do
      {:ok,
       {:recoverable,
        Arbor.Agent.Orchestration.TaskControlCrashReplaySecurityRegressionTest.probe_projection(
          agent_id,
          context,
          "c"
        )}}
    end
  end

  defmodule RecoverFail do
    @moduledoc false
    def run(_, _, _), do: Process.sleep(60_000)
    def recover_task(_, _), do: {:error, {:pipeline_error, %{"status" => "failed"}}}

    def probe_recovery(agent_id, context) do
      {:ok,
       {:recoverable,
        Arbor.Agent.Orchestration.TaskControlCrashReplaySecurityRegressionTest.probe_projection(
          agent_id,
          context,
          "d"
        )}}
    end
  end

  defmodule ProbeUnavailable do
    @moduledoc false
    def run(_, _, _), do: Process.sleep(60_000)
    def recover_task(_, _), do: {:ok, %{}}
    def probe_recovery(_, _), do: {:error, :unavailable}
  end

  defmodule ProbeOrphan do
    @moduledoc false
    def run(_, _, _), do: Process.sleep(60_000)
    def recover_task(_, _), do: {:ok, %{}}
    def probe_recovery(_, _), do: {:ok, :orphan}
  end

  defmodule RecoverFinalizeFail do
    @moduledoc false
    def run(_, _, _), do: {:ok, %{"status" => "success"}}

    def recover_task(_agent_id, _context) do
      {:ok, %{"status" => "success", "artifacts" => %{}}}
    end

    def probe_recovery(agent_id, context) do
      {:ok,
       {:recoverable,
        Arbor.Agent.Orchestration.TaskControlCrashReplaySecurityRegressionTest.probe_projection(
          agent_id,
          context,
          "f"
        )}}
    end

    def finalize_terminal_task(_agent_id, _envelope, _controls, _context) do
      {:error, :forced_finalizer_failure}
    end
  end

  defmodule UnavailableInventorySecurity do
    @moduledoc false
    defdelegate grant(opts), to: TrackingSecurity
    defdelegate revoke(id), to: TrackingSecurity
    defdelegate revoke_by_task(task_id), to: TrackingSecurity
    defdelegate caps_for(task_id), to: TrackingSecurity
    defdelegate listed_principals(), to: TrackingSecurity
    def list_capabilities(_principal, _opts \\ []), do: {:error, :eio}
  end

  defmodule MismatchControlProbe do
    @moduledoc false
    def run(_, _, _), do: {:ok, %{}}
    def recover_task(_, _), do: {:ok, %{"status" => "success"}}

    def probe_recovery(agent_id, context) do
      projection =
        Arbor.Agent.Orchestration.TaskControlCrashReplaySecurityRegressionTest.probe_projection(
          agent_id,
          context,
          "a"
        )
        |> Map.put("control_principal_id", "other_caller")

      {:ok, {:recoverable, projection}}
    end
  end

  defmodule MismatchAgentProbe do
    @moduledoc false
    def run(_, _, _), do: {:ok, %{}}
    def recover_task(_, _), do: {:ok, %{"status" => "success"}}

    def probe_recovery(agent_id, context) do
      projection =
        Arbor.Agent.Orchestration.TaskControlCrashReplaySecurityRegressionTest.probe_projection(
          agent_id,
          context,
          "a"
        )
        |> Map.put("agent_id", "agent_other")
        |> Map.put("execution_principal", "agent_other")

      {:ok, {:recoverable, projection}}
    end
  end

  defmodule MismatchExecutorProbe do
    @moduledoc false
    def run(_, _, _), do: {:ok, %{}}
    def recover_task(_, _), do: {:ok, %{"status" => "success"}}

    def probe_recovery(agent_id, context) do
      projection =
        Arbor.Agent.Orchestration.TaskControlCrashReplaySecurityRegressionTest.probe_projection(
          agent_id,
          context,
          "a"
        )
        |> Map.put("executor_kind", "other_kind")

      {:ok, {:recoverable, projection}}
    end
  end

  defmodule MismatchRunProbe do
    @moduledoc false
    def run(_, _, _), do: {:ok, %{}}
    def recover_task(_, _), do: {:ok, %{"status" => "success"}}

    def probe_recovery(agent_id, context) do
      projection =
        Arbor.Agent.Orchestration.TaskControlCrashReplaySecurityRegressionTest.probe_projection(
          agent_id,
          context,
          "a"
        )
        |> Map.put("run_id", "task_other")
        |> Map.put("task_id", "task_other")

      {:ok, {:recoverable, projection}}
    end
  end

  setup do
    TrackingSecurity.ensure!()
    TrackingSecurity.reset!()
    TaskControlRecoveryMemory.ensure!()
    TaskControlRecoveryMemory.reset!()
    :ok
  end

  test "security regression: durable marker replay revokes task-scoped authority after TaskStore restart" do
    supervisor = start_supervised!({Task.Supervisor, name: unique(:sup)})
    store_name = unique(:store)

    store =
      start_supervised!(
        {TaskStore,
         name: store_name,
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         recovery_force_ready: true,
         task_control_recovery_facade: TaskControlRecoveryMemory,
         task_control_security_module: TrackingSecurity,
         runner: __MODULE__.HangRunner},
        id: store_name
      )

    assert {:ok, %{task_id: task_id, reservation_token: token}} =
             TaskStore.reserve("agent_1", name: store)

    assert :ok = TaskStore.commit_recovery_marker(task_id, token, name: store)

    # Mint six caps under task scope (simulates post-marker grants).
    for kind <- TaskControlLease.grant_order() do
      {:ok, spec} = TaskControlLease.grant_spec(kind, "caller_1", task_id, DateTime.utc_now())
      assert {:ok, _} = TrackingSecurity.grant(spec)
    end

    assert length(TrackingSecurity.caps_for(task_id)) == 6

    # Marker still durable.
    assert {:ok, _marker} =
             TaskControlRecoveryMemory.buffered_store_authoritative_get(
               :arbor_agent_task_control_recovery,
               task_id
             )

    # Crash the store and restart with replay enabled (not force-ready).
    true = Process.exit(store, :kill)
    Process.sleep(30)

    store2_name = unique(:store2)

    store2 =
      start_supervised!(
        {TaskStore,
         name: store2_name,
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         recovery_force_ready: false,
         task_control_recovery_facade: TaskControlRecoveryMemory,
         task_control_security_module: TrackingSecurity,
         runner: __MODULE__.HangRunner},
        id: store2_name
      )

    assert wait_until(fn -> TaskStore.recovery_ready?(name: store2) end)

    assert task_id in TrackingSecurity.revokes_by_task()
    assert TrackingSecurity.caps_for(task_id) == []

    # Marker deleted after confirmed reconcile (or not_found).
    assert {:error, :not_found} =
             TaskControlRecoveryMemory.buffered_store_authoritative_get(
               :arbor_agent_task_control_recovery,
               task_id
             )

    # New work accepted only after ready.
    assert {:ok, %{task_id: _new_id}} = TaskStore.reserve("agent_1", name: store2)
  end

  test "security regression: non-nil lease activation fails closed without backend-acked marker" do
    supervisor = start_supervised!({Task.Supervisor, name: unique(:sup_gate)})
    store_name = unique(:store_gate)

    store =
      start_supervised!(
        {TaskStore,
         name: store_name,
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         recovery_force_ready: true,
         task_control_recovery_facade: TaskControlRecoveryMemory,
         task_control_security_module: TrackingSecurity,
         runner: __MODULE__.HangRunner},
        id: store_name
      )

    assert {:ok, %{task_id: task_id, reservation_token: token}} =
             TaskStore.reserve("agent_1", name: store)

    # Simulate post-reserve grants without a durable marker ack first — the
    # production path must never activate a non-nil lease in this window.
    for kind <- TaskControlLease.grant_order() do
      {:ok, spec} = TaskControlLease.grant_spec(kind, "caller_1", task_id, DateTime.utc_now())
      assert {:ok, _} = TrackingSecurity.grant(spec)
    end

    assert length(TrackingSecurity.caps_for(task_id)) == 6

    ids = Map.new(TaskControlLease.kinds(), fn k -> {k, "cap_#{k}_sec_gate"} end)
    assert {:ok, lease} = TaskControlLease.new(task_id, ids)

    # Security gate: lease activation without marker ack fails closed.
    # Parent 6ec5933b admits here (no marker_written? check) — candidate rejects.
    assert {:error, :recovery_marker_required} =
             TaskStore.activate("agent_1", "work", task_id, token,
               name: store,
               task_control_lease: lease
             )

    # Caps remain task-scoped; no running task was admitted without the marker.
    assert length(TrackingSecurity.caps_for(task_id)) == 6
    assert {:error, :not_found} = TaskStore.status(task_id, name: store)

    # After durable marker ack, activation is allowed.
    assert :ok = TaskStore.commit_recovery_marker(task_id, token, name: store)

    assert {:ok, ^task_id} =
             TaskStore.activate("agent_1", "work", task_id, token,
               name: store,
               task_control_lease: lease
             )

    assert {:ok, %{task_id: ^task_id, state: :running}} =
             TaskStore.status(task_id, name: store)
  end

  test "security regression: recoverable v2 marker retains caller-scoped caps and marker" do
    previous = Application.get_env(:arbor_agent, :task_executors, %{})

    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => __MODULE__.HangRecover
    })

    on_exit(fn ->
      Application.put_env(:arbor_agent, :task_executors, previous)
    end)

    supervisor = start_supervised!({Task.Supervisor, name: unique(:sup_rec)})
    store_name = unique(:store_rec)

    store =
      start_supervised!(
        {TaskStore,
         name: store_name,
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         recovery_force_ready: true,
         task_control_recovery_facade: TaskControlRecoveryMemory,
         task_control_security_module: TrackingSecurity,
         runner: __MODULE__.HangRecover},
        id: store_name
      )

    assert {:ok, %{task_id: task_id, reservation_token: token}} =
             TaskStore.reserve("agent_target", name: store)

    assert :ok =
             TaskStore.commit_recovery_marker(task_id, token,
               name: store,
               agent_id: "agent_target",
               executor_kind: "coding_change",
               control_principal_id: "caller_control",
               cleanup: %{"caller_id" => "caller_control", "principal_id" => "agent_target"}
             )

    for kind <- TaskControlLease.grant_order() do
      {:ok, spec} =
        TaskControlLease.grant_spec(kind, "caller_control", task_id, DateTime.utc_now())

      assert {:ok, _} = TrackingSecurity.grant(spec)
    end

    assert length(TrackingSecurity.caps_for(task_id)) == 6

    true = Process.exit(store, :kill)
    Process.sleep(30)

    store2_name = unique(:store_rec2)

    store2 =
      start_supervised!(
        {TaskStore,
         name: store2_name,
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         recovery_force_ready: false,
         task_control_recovery_facade: TaskControlRecoveryMemory,
         task_control_security_module: TrackingSecurity,
         runner: __MODULE__.HangRecover},
        id: store2_name
      )

    assert wait_until(fn -> TaskStore.recovery_ready?(name: store2) end)
    refute task_id in TrackingSecurity.revokes_by_task()
    assert length(TrackingSecurity.caps_for(task_id)) == 6

    assert {:ok, _marker} =
             TaskControlRecoveryMemory.buffered_store_authoritative_get(
               :arbor_agent_task_control_recovery,
               task_id
             )

    assert TrackingSecurity.listed_principals() |> Enum.all?(&(&1 != "agent_target"))
    assert "caller_control" in TrackingSecurity.listed_principals()

    assert wait_until(fn ->
             match?({:ok, %{state: :running}}, TaskStore.status(task_id, name: store2))
           end)
  end

  test "security regression: v2 marker without recover_task still orphans" do
    previous = Application.get_env(:arbor_agent, :task_executors, %{})

    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => __MODULE__.HangRunner
    })

    on_exit(fn ->
      Application.put_env(:arbor_agent, :task_executors, previous)
    end)

    supervisor = start_supervised!({Task.Supervisor, name: unique(:sup_orph)})
    store_name = unique(:store_orph)

    store =
      start_supervised!(
        {TaskStore,
         name: store_name,
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         recovery_force_ready: true,
         task_control_recovery_facade: TaskControlRecoveryMemory,
         task_control_security_module: TrackingSecurity,
         runner: __MODULE__.HangRunner},
        id: store_name
      )

    assert {:ok, %{task_id: task_id, reservation_token: token}} =
             TaskStore.reserve("agent_target", name: store)

    assert :ok =
             TaskStore.commit_recovery_marker(task_id, token,
               name: store,
               agent_id: "agent_target",
               executor_kind: "coding_change",
               control_principal_id: "caller_control",
               cleanup: %{"caller_id" => "caller_control", "principal_id" => "agent_target"}
             )

    for kind <- TaskControlLease.grant_order() do
      {:ok, spec} =
        TaskControlLease.grant_spec(kind, "caller_control", task_id, DateTime.utc_now())

      assert {:ok, _} = TrackingSecurity.grant(spec)
    end

    true = Process.exit(store, :kill)
    Process.sleep(30)

    store2_name = unique(:store_orph2)

    store2 =
      start_supervised!(
        {TaskStore,
         name: store2_name,
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         recovery_force_ready: false,
         task_control_recovery_facade: TaskControlRecoveryMemory,
         task_control_security_module: TrackingSecurity,
         runner: __MODULE__.HangRunner},
        id: store2_name
      )

    assert wait_until(fn -> TaskStore.recovery_ready?(name: store2) end)
    assert task_id in TrackingSecurity.revokes_by_task()
    assert TrackingSecurity.caps_for(task_id) == []

    assert {:error, :not_found} =
             TaskControlRecoveryMemory.buffered_store_authoritative_get(
               :arbor_agent_task_control_recovery,
               task_id
             )
  end

  test "recovered terminal is observable through TaskStore status and result" do
    previous = Application.get_env(:arbor_agent, :task_executors, %{})

    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => __MODULE__.RecoverSuccess
    })

    on_exit(fn ->
      Application.put_env(:arbor_agent, :task_executors, previous)
    end)

    supervisor = start_supervised!({Task.Supervisor, name: unique(:sup_ok)})
    store_name = unique(:store_ok)

    store =
      start_supervised!(
        {TaskStore,
         name: store_name,
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         recovery_force_ready: true,
         task_control_recovery_facade: TaskControlRecoveryMemory,
         task_control_security_module: TrackingSecurity,
         runner: __MODULE__.RecoverSuccess},
        id: store_name
      )

    assert {:ok, %{task_id: task_id, reservation_token: token}} =
             TaskStore.reserve("agent_target", name: store)

    assert :ok =
             TaskStore.commit_recovery_marker(task_id, token,
               name: store,
               agent_id: "agent_target",
               executor_kind: "coding_change",
               control_principal_id: "caller_control",
               cleanup: %{"caller_id" => "caller_control", "principal_id" => "agent_target"}
             )

    true = Process.exit(store, :kill)
    Process.sleep(30)

    store2_name = unique(:store_ok2)

    store2 =
      start_supervised!(
        {TaskStore,
         name: store2_name,
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         recovery_force_ready: false,
         task_control_recovery_facade: TaskControlRecoveryMemory,
         task_control_security_module: TrackingSecurity,
         runner: __MODULE__.RecoverSuccess},
        id: store2_name
      )

    assert wait_until(fn -> TaskStore.recovery_ready?(name: store2) end)

    assert wait_until(fn ->
             match?({:ok, %{state: :done}}, TaskStore.status(task_id, name: store2))
           end)

    assert {:ok, result} = TaskStore.result(task_id, name: store2)

    assert %{result_type: :value, payload: %{value: %{"status" => "success"}}} = result
  end

  test "recovered graph/domain failure is observable as a failed TaskStore terminal" do
    previous = Application.get_env(:arbor_agent, :task_executors, %{})

    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => __MODULE__.RecoverFail
    })

    on_exit(fn -> Application.put_env(:arbor_agent, :task_executors, previous) end)

    supervisor = start_supervised!({Task.Supervisor, name: unique(:sup_fail)})
    store = start_store(supervisor, unique(:store_fail), __MODULE__.RecoverFail)

    assert {:ok, %{task_id: task_id, reservation_token: token}} =
             TaskStore.reserve("agent_target", name: store)

    assert :ok = commit_v2(store, task_id, token)
    true = Process.exit(store, :kill)
    Process.sleep(30)

    store2 =
      start_store(supervisor, unique(:store_fail2), __MODULE__.RecoverFail, force_ready: false)

    assert wait_until(fn -> TaskStore.recovery_ready?(name: store2) end)

    assert wait_until(fn ->
             match?({:ok, %{state: :failed}}, TaskStore.status(task_id, name: store2))
           end)
  end

  test "recovered success with finalizer failure still terminalizes" do
    previous = Application.get_env(:arbor_agent, :task_executors, %{})

    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => __MODULE__.RecoverFinalizeFail
    })

    on_exit(fn -> Application.put_env(:arbor_agent, :task_executors, previous) end)

    supervisor = start_supervised!({Task.Supervisor, name: unique(:sup_fin)})
    store = start_store(supervisor, unique(:store_fin), __MODULE__.RecoverFinalizeFail)

    assert {:ok, %{task_id: task_id, reservation_token: token}} =
             TaskStore.reserve("agent_target", name: store)

    assert :ok = commit_v2(store, task_id, token)
    true = Process.exit(store, :kill)
    Process.sleep(30)

    store2 =
      start_store(supervisor, unique(:store_fin2), __MODULE__.RecoverFinalizeFail,
        force_ready: false
      )

    assert wait_until(fn -> TaskStore.recovery_ready?(name: store2) end)

    assert wait_until(fn ->
             match?(
               {:ok, %{state: state}} when state in [:done, :failed],
               TaskStore.status(task_id, name: store2)
             )
           end)
  end

  test "recovered {:error, :cancelled} maps to TaskStore cancelled not failed" do
    previous = Application.get_env(:arbor_agent, :task_executors, %{})

    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => __MODULE__.RecoverCancel
    })

    on_exit(fn -> Application.put_env(:arbor_agent, :task_executors, previous) end)

    supervisor = start_supervised!({Task.Supervisor, name: unique(:sup_can)})
    store = start_store(supervisor, unique(:store_can), __MODULE__.RecoverCancel)

    assert {:ok, %{task_id: task_id, reservation_token: token}} =
             TaskStore.reserve("agent_target", name: store)

    assert :ok = commit_v2(store, task_id, token)
    true = Process.exit(store, :kill)
    Process.sleep(30)

    store2 =
      start_store(supervisor, unique(:store_can2), __MODULE__.RecoverCancel, force_ready: false)

    assert wait_until(fn -> TaskStore.recovery_ready?(name: store2) end)

    assert wait_until(fn ->
             match?({:ok, %{state: :cancelled}}, TaskStore.status(task_id, name: store2))
           end)

    assert {:ok, %{state: :cancelled}} = TaskStore.status(task_id, name: store2)
    assert {:ok, envelope} = TaskStore.result(task_id, name: store2)
    assert envelope["terminal_state"] == "cancelled"
    assert get_in(envelope, ["evidence", "kind"]) == "task_cancelled"
    assert get_in(envelope, ["outcome", "code"]) == "task_cancelled"
  end

  test "security regression: probe orphan routes through revoke_by_task and marker delete" do
    previous = Application.get_env(:arbor_agent, :task_executors, %{})

    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => __MODULE__.ProbeOrphan
    })

    on_exit(fn -> Application.put_env(:arbor_agent, :task_executors, previous) end)

    supervisor = start_supervised!({Task.Supervisor, name: unique(:sup_porph)})
    store = start_store(supervisor, unique(:store_porph), __MODULE__.ProbeOrphan)

    assert {:ok, %{task_id: task_id, reservation_token: token}} =
             TaskStore.reserve("agent_target", name: store)

    assert :ok = commit_v2(store, task_id, token)

    for kind <- TaskControlLease.grant_order() do
      {:ok, spec} =
        TaskControlLease.grant_spec(kind, "caller_control", task_id, DateTime.utc_now())

      assert {:ok, _} = TrackingSecurity.grant(spec)
    end

    true = Process.exit(store, :kill)
    Process.sleep(30)

    store2 =
      start_store(supervisor, unique(:store_porph2), __MODULE__.ProbeOrphan, force_ready: false)

    assert wait_until(fn -> TaskStore.recovery_ready?(name: store2) end)
    assert task_id in TrackingSecurity.revokes_by_task()
    assert TrackingSecurity.caps_for(task_id) == []

    assert {:error, :not_found} =
             TaskControlRecoveryMemory.buffered_store_authoritative_get(
               :arbor_agent_task_control_recovery,
               task_id
             )
  end

  test "startup probe outage keeps the marker and does not declare ready" do
    previous = Application.get_env(:arbor_agent, :task_executors, %{})

    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => __MODULE__.ProbeUnavailable
    })

    on_exit(fn -> Application.put_env(:arbor_agent, :task_executors, previous) end)

    supervisor = start_supervised!({Task.Supervisor, name: unique(:sup_unav)})
    store = start_store(supervisor, unique(:store_unav), __MODULE__.ProbeUnavailable)

    assert {:ok, %{task_id: task_id, reservation_token: token}} =
             TaskStore.reserve("agent_target", name: store)

    assert :ok = commit_v2(store, task_id, token)
    true = Process.exit(store, :kill)
    Process.sleep(30)

    store2 =
      start_store(supervisor, unique(:store_unav2), __MODULE__.ProbeUnavailable,
        force_ready: false
      )

    Process.sleep(200)
    refute TaskStore.recovery_ready?(name: store2)

    assert {:ok, _marker} =
             TaskControlRecoveryMemory.buffered_store_authoritative_get(
               :arbor_agent_task_control_recovery,
               task_id
             )
  end

  test "partial control inventory is preserved instead of dropping the lease" do
    previous = Application.get_env(:arbor_agent, :task_executors, %{})

    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => __MODULE__.HangRecover
    })

    on_exit(fn -> Application.put_env(:arbor_agent, :task_executors, previous) end)

    supervisor = start_supervised!({Task.Supervisor, name: unique(:sup_part)})
    store = start_store(supervisor, unique(:store_part), __MODULE__.HangRecover)

    assert {:ok, %{task_id: task_id, reservation_token: token}} =
             TaskStore.reserve("agent_target", name: store)

    assert :ok = commit_v2(store, task_id, token)

    for kind <- [:task_read, :task_cancel] do
      {:ok, spec} =
        TaskControlLease.grant_spec(kind, "caller_control", task_id, DateTime.utc_now())

      assert {:ok, _} = TrackingSecurity.grant(spec)
    end

    true = Process.exit(store, :kill)
    Process.sleep(30)

    store2 =
      start_store(supervisor, unique(:store_part2), __MODULE__.HangRecover, force_ready: false)

    assert wait_until(fn -> TaskStore.recovery_ready?(name: store2) end)
    refute task_id in TrackingSecurity.revokes_by_task()
    assert length(TrackingSecurity.caps_for(task_id)) == 2

    assert wait_until(fn ->
             match?({:ok, %{state: :running}}, TaskStore.status(task_id, name: store2))
           end)
  end

  test "control inventory transport outage does not declare ready or drop caps" do
    previous = Application.get_env(:arbor_agent, :task_executors, %{})

    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => __MODULE__.HangRecover
    })

    on_exit(fn -> Application.put_env(:arbor_agent, :task_executors, previous) end)

    supervisor = start_supervised!({Task.Supervisor, name: unique(:sup_inv)})

    store =
      start_supervised!(
        {TaskStore,
         name: unique(:store_inv),
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         recovery_force_ready: true,
         task_control_recovery_facade: TaskControlRecoveryMemory,
         task_control_security_module: TrackingSecurity,
         runner: __MODULE__.HangRecover},
        id: unique(:store_inv_id)
      )

    assert {:ok, %{task_id: task_id, reservation_token: token}} =
             TaskStore.reserve("agent_target", name: store)

    assert :ok = commit_v2(store, task_id, token)

    for kind <- TaskControlLease.grant_order() do
      {:ok, spec} =
        TaskControlLease.grant_spec(kind, "caller_control", task_id, DateTime.utc_now())

      assert {:ok, _} = TrackingSecurity.grant(spec)
    end

    true = Process.exit(store, :kill)
    Process.sleep(30)

    store2_name = unique(:store_inv2)

    store2 =
      start_supervised!(
        {TaskStore,
         name: store2_name,
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         recovery_force_ready: false,
         task_control_recovery_facade: TaskControlRecoveryMemory,
         task_control_security_module: UnavailableInventorySecurity,
         runner: __MODULE__.HangRecover},
        id: store2_name
      )

    Process.sleep(200)
    refute TaskStore.recovery_ready?(name: store2)
    assert length(TrackingSecurity.caps_for(task_id)) == 6
  end

  test "replay remains complete across more recoverable markers than one batch" do
    previous = Application.get_env(:arbor_agent, :task_executors, %{})

    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => __MODULE__.RecoverSuccess
    })

    on_exit(fn -> Application.put_env(:arbor_agent, :task_executors, previous) end)

    supervisor = start_supervised!({Task.Supervisor, name: unique(:sup_batch)})
    store_name = unique(:store_batch)

    store =
      start_supervised!(
        {TaskStore,
         name: store_name,
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         recovery_force_ready: true,
         recovery_replay_batch: 2,
         task_control_recovery_facade: TaskControlRecoveryMemory,
         task_control_security_module: TrackingSecurity,
         runner: __MODULE__.RecoverSuccess},
        id: store_name
      )

    task_ids =
      for _ <- 1..5 do
        assert {:ok, %{task_id: task_id, reservation_token: token}} =
                 TaskStore.reserve("agent_target", name: store)

        assert :ok = commit_v2(store, task_id, token)
        task_id
      end

    true = Process.exit(store, :kill)
    Process.sleep(30)

    store2_name = unique(:store_batch2)

    store2 =
      start_supervised!(
        {TaskStore,
         name: store2_name,
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         recovery_force_ready: false,
         recovery_replay_batch: 2,
         task_control_recovery_facade: TaskControlRecoveryMemory,
         task_control_security_module: TrackingSecurity,
         runner: __MODULE__.RecoverSuccess},
        id: store2_name
      )

    assert wait_until(fn -> TaskStore.recovery_ready?(name: store2) end, 200)

    for task_id <- task_ids do
      assert wait_until(fn ->
               match?({:ok, %{state: :done}}, TaskStore.status(task_id, name: store2))
             end)
    end
  end

  test "causal join: mismatched control_principal_id does not reconstruct controls" do
    refute_mismatched_spawn(__MODULE__.MismatchControlProbe, unique(:sup_mc), unique(:store_mc))
  end

  test "causal join: mismatched agent_id does not reconstruct controls" do
    refute_mismatched_spawn(__MODULE__.MismatchAgentProbe, unique(:sup_ma), unique(:store_ma))
  end

  test "causal join: mismatched executor_kind does not reconstruct controls" do
    refute_mismatched_spawn(__MODULE__.MismatchExecutorProbe, unique(:sup_me), unique(:store_me))
  end

  test "causal join: mismatched run_id does not reconstruct controls" do
    refute_mismatched_spawn(__MODULE__.MismatchRunProbe, unique(:sup_mr), unique(:store_mr))
  end

  test "security regression: duplicate equal ids reconstruct; conflicting ids stay retryable" do
    task_id_equal = recover_with_listed_caps(:equal)
    assert is_binary(task_id_equal)

    previous = Application.get_env(:arbor_agent, :task_executors, %{})

    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => __MODULE__.HangRecover
    })

    on_exit(fn -> Application.put_env(:arbor_agent, :task_executors, previous) end)

    supervisor = start_supervised!({Task.Supervisor, name: unique(:sup_conf)})
    store = start_store(supervisor, unique(:store_conf), __MODULE__.HangRecover)

    assert {:ok, %{task_id: task_id, reservation_token: token}} =
             TaskStore.reserve("agent_target", name: store)

    assert :ok = commit_v2(store, task_id, token)

    {:ok, uri} = TaskControlLease.uri(:task_read, task_id)

    TrackingSecurity.ensure!()

    caps =
      case :ets.lookup(:task_control_crash_replay_security, :caps) do
        [{:caps, map}] -> map
        _ -> %{}
      end

    records = [
      %{id: "cap_read_a", resource_uri: uri, task_id: task_id},
      %{id: "cap_read_b", resource_uri: uri, task_id: task_id}
    ]

    :ets.insert(:task_control_crash_replay_security, {:caps, Map.put(caps, task_id, records)})

    true = Process.exit(store, :kill)
    Process.sleep(30)

    store2 =
      start_store(supervisor, unique(:store_conf2), __MODULE__.HangRecover, force_ready: false)

    Process.sleep(200)
    refute match?({:ok, %{state: :running}}, TaskStore.status(task_id, name: store2))
    refute TaskStore.recovery_ready?(name: store2)
    assert length(TrackingSecurity.caps_for(task_id)) == 2

    assert {:ok, _marker} =
             TaskControlRecoveryMemory.buffered_store_authoritative_get(
               :arbor_agent_task_control_recovery,
               task_id
             )
  end

  test "recovered terminal revokes active controls and retains task read" do
    previous = Application.get_env(:arbor_agent, :task_executors, %{})

    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => __MODULE__.RecoverSuccess
    })

    on_exit(fn -> Application.put_env(:arbor_agent, :task_executors, previous) end)

    supervisor = start_supervised!({Task.Supervisor, name: unique(:sup_termc)})
    store = start_store(supervisor, unique(:store_termc), __MODULE__.RecoverSuccess)

    assert {:ok, %{task_id: task_id, reservation_token: token}} =
             TaskStore.reserve("agent_target", name: store)

    assert :ok = commit_v2(store, task_id, token)

    for kind <- TaskControlLease.grant_order() do
      {:ok, spec} =
        TaskControlLease.grant_spec(kind, "caller_control", task_id, DateTime.utc_now())

      assert {:ok, _} = TrackingSecurity.grant(spec)
    end

    true = Process.exit(store, :kill)
    Process.sleep(30)

    store2 =
      start_store(supervisor, unique(:store_termc2), __MODULE__.RecoverSuccess,
        force_ready: false
      )

    assert wait_until(fn -> TaskStore.recovery_ready?(name: store2) end)

    assert wait_until(fn ->
             match?({:ok, %{state: :done}}, TaskStore.status(task_id, name: store2))
           end)

    assert wait_until(fn -> length(TrackingSecurity.caps_for(task_id)) == 1 end)

    assert {:ok, [remaining]} =
             TrackingSecurity.list_capabilities("caller_control", task_id: task_id)

    assert {:ok, remaining.resource_uri} == TaskControlLease.uri(:task_read, task_id)
  end

  def probe_projection(agent_id, context, digest_char) do
    task_id = Map.get(context, "task_id", "task_unknown")
    control = Map.get(context, "control_principal_id", "caller_control")
    kind = Map.get(context, "executor_kind", "coding_change")
    digest = String.duplicate(digest_char, 64)

    %{
      "schema_version" => 1,
      "task_id" => task_id,
      "run_id" => task_id,
      "agent_id" => agent_id,
      "execution_principal" => agent_id,
      "control_principal_id" => control,
      "executor_kind" => kind,
      "graph_hash" => digest,
      "artifact_identity" => digest,
      "binding_digest" => digest
    }
  end

  defp refute_mismatched_spawn(runner, sup_name, store_name) do
    previous = Application.get_env(:arbor_agent, :task_executors, %{})
    Application.put_env(:arbor_agent, :task_executors, %{"coding_change" => runner})
    on_exit(fn -> Application.put_env(:arbor_agent, :task_executors, previous) end)

    supervisor = start_supervised!({Task.Supervisor, name: sup_name})
    store = start_store(supervisor, store_name, runner)

    assert {:ok, %{task_id: task_id, reservation_token: token}} =
             TaskStore.reserve("agent_target", name: store)

    assert :ok = commit_v2(store, task_id, token)

    for kind <- TaskControlLease.grant_order() do
      {:ok, spec} =
        TaskControlLease.grant_spec(kind, "caller_control", task_id, DateTime.utc_now())

      assert {:ok, _} = TrackingSecurity.grant(spec)
    end

    true = Process.exit(store, :kill)
    Process.sleep(30)

    store2 = start_store(supervisor, unique(:store_mm2), runner, force_ready: false)
    assert wait_until(fn -> TaskStore.recovery_ready?(name: store2) end)
    refute match?({:ok, %{state: :running}}, TaskStore.status(task_id, name: store2))
    refute "caller_control" in TrackingSecurity.listed_principals()
    assert task_id in TrackingSecurity.revokes_by_task()
  end

  defp recover_with_listed_caps(:equal) do
    previous = Application.get_env(:arbor_agent, :task_executors, %{})

    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => __MODULE__.HangRecover
    })

    on_exit(fn -> Application.put_env(:arbor_agent, :task_executors, previous) end)

    supervisor = start_supervised!({Task.Supervisor, name: unique(:sup_eq)})
    store = start_store(supervisor, unique(:store_eq), __MODULE__.HangRecover)

    assert {:ok, %{task_id: task_id, reservation_token: token}} =
             TaskStore.reserve("agent_target", name: store)

    assert :ok = commit_v2(store, task_id, token)
    {:ok, uri} = TaskControlLease.uri(:task_read, task_id)
    TrackingSecurity.ensure!()

    records = [
      %{id: "cap_read_same", resource_uri: uri, task_id: task_id},
      %{id: "cap_read_same", resource_uri: uri, task_id: task_id}
    ]

    :ets.insert(
      :task_control_crash_replay_security,
      {:caps, %{task_id => records}}
    )

    true = Process.exit(store, :kill)
    Process.sleep(30)

    store2 =
      start_store(supervisor, unique(:store_eq2), __MODULE__.HangRecover, force_ready: false)

    assert wait_until(fn -> TaskStore.recovery_ready?(name: store2) end)

    assert wait_until(fn ->
             match?({:ok, %{state: :running}}, TaskStore.status(task_id, name: store2))
           end)

    task_id
  end

  defp unique(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  defp start_store(supervisor, name, runner, opts \\ []) do
    start_supervised!(
      {TaskStore,
       [
         {:name, name},
         {:task_supervisor, supervisor},
         {:cleanup_supervisor, supervisor},
         {:recovery_force_ready, Keyword.get(opts, :force_ready, true)},
         {:task_control_recovery_facade, TaskControlRecoveryMemory},
         {:task_control_security_module, Keyword.get(opts, :security, TrackingSecurity)},
         {:runner, runner}
       ]},
      id: name
    )
  end

  defp commit_v2(store, task_id, token) do
    TaskStore.commit_recovery_marker(task_id, token,
      name: store,
      agent_id: "agent_target",
      executor_kind: "coding_change",
      control_principal_id: "caller_control",
      cleanup: %{"caller_id" => "caller_control", "principal_id" => "agent_target"}
    )
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() ->
        true

      attempts <= 0 ->
        flunk("timeout waiting for recovery_ready")

      true ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)
    end
  end
end
