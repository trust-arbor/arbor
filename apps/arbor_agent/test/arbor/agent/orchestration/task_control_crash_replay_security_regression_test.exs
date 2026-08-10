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
      :ets.insert(@table, {:caps, Map.put(caps, task_id, [id | task_caps])})
      {:ok, %{id: id, resource_uri: opts[:resource], task_id: task_id}}
    end

    def revoke(id) do
      ensure!()

      caps =
        case :ets.lookup(@table, :caps) do
          [{:caps, map}] ->
            Enum.reduce(map, %{}, fn {tid, ids}, acc ->
              Map.put(acc, tid, List.delete(ids, id))
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
        [{:caps, map}] -> Map.get(map, task_id, [])
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

  defp unique(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

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
