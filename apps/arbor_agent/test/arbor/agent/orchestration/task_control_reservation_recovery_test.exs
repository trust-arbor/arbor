defmodule Arbor.Agent.Orchestration.TaskControlReservationRecoveryTest do
  # Shares TaskControlRecoveryMemory ETS with operator rework / crash-replay —
  # run synchronously to avoid cross-suite reset races.
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Agent.Orchestration
  alias Arbor.Agent.Orchestration.{TaskControlLease, TaskControlRecoveryMemory, TaskStore}

  defmodule HangRunner do
    @moduledoc false
    def run(_a, _t, _o) do
      Process.sleep(60_000)
      {:ok, %{}}
    end
  end

  defmodule NoopSecurity do
    @moduledoc false
    def grant(opts) do
      kind = get_in(opts, [:metadata, :kind]) || "k"
      id = "cap_#{kind}_#{System.unique_integer([:positive])}"
      {:ok, %{id: id, resource_uri: opts[:resource], task_id: opts[:task_id]}}
    end

    def revoke(_id), do: :ok
    def revoke_by_task(_task_id), do: {:ok, 0}
  end

  # Keeps retirement members pending by failing every member revoke.
  defmodule FailRevokeSecurity do
    @moduledoc false
    def grant(opts) do
      kind = get_in(opts, [:metadata, :kind]) || "k"
      id = "cap_#{kind}_#{System.unique_integer([:positive])}"
      {:ok, %{id: id, resource_uri: opts[:resource], task_id: opts[:task_id]}}
    end

    def revoke(_id), do: {:error, :injected_revoke_failure}
    def revoke_by_task(_task_id), do: {:error, :injected_revoke_by_task_failure}
  end

  setup do
    TaskControlRecoveryMemory.ensure!()
    TaskControlRecoveryMemory.reset!()
    supervisor = start_supervised!({Task.Supervisor, name: unique(:sup)})

    store =
      start_supervised!(
        {TaskStore,
         name: unique(:store),
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         recovery_force_ready: true,
         task_control_recovery_facade: TaskControlRecoveryMemory,
         task_control_security_module: NoopSecurity,
         runner: HangRunner}
      )

    %{store: store, supervisor: supervisor}
  end

  test "reserve generates server-owned id and requires token for activate", %{store: store} do
    assert {:ok, %{task_id: task_id, reservation_token: token}} =
             TaskStore.reserve("agent_1", name: store)

    assert TaskControlLease.valid_task_id?(task_id)
    assert is_binary(token)

    assert {:error, :invalid_reservation_token} =
             TaskStore.activate("agent_1", "work", task_id, "forged_token_xxxxxxxxxxxx",
               name: store
             )

    assert :ok =
             TaskStore.commit_recovery_marker(task_id, token, name: store)

    assert {:ok, ^task_id} =
             TaskStore.activate("agent_1", "work", task_id, token, name: store)

    assert {:ok, %{task_id: ^task_id, state: :running}} =
             TaskStore.status(task_id, name: store)
  end

  test "capacity exhausted fails reserve without dropping retirement members", %{
    supervisor: supervisor
  } do
    name = unique(:cap_store)

    # Pin failing revoke so retirement members stay pending (NoopSecurity would
    # clear the bucket as soon as revokes succeed — flaky under capacity stress).
    store2 =
      start_supervised!(
        {TaskStore,
         name: name,
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         recovery_force_ready: true,
         task_control_recovery_facade: TaskControlRecoveryMemory,
         task_control_security_module: FailRevokeSecurity,
         max_recovery_obligations: 1,
         max_reservations: 1,
         runner: HangRunner},
        id: name
      )

    assert {:ok, %{task_id: t1, reservation_token: tok1}} =
             TaskStore.reserve("agent_1", name: store2)

    assert {:error, :reservation_capacity_exhausted} = TaskStore.reserve("agent_1", name: store2)

    # Terminal retirement still accepts members even at capacity (no drop).
    ids = Map.new(TaskControlLease.kinds(), fn k -> {k, "cap_#{k}_cap"} end)
    {:ok, lease} = TaskControlLease.new(t1, ids)

    assert :ok = TaskStore.commit_recovery_marker(t1, tok1, name: store2)

    assert {:ok, ^t1} =
             TaskStore.activate("agent_1", "work", t1, tok1,
               name: store2,
               task_control_lease: lease
             )

    assert {:ok, _} = TaskStore.cancel(t1, name: store2)

    assert wait_until(fn ->
             {:ok, snap} = TaskStore.lease_retirement_snapshot(name: store2)
             pending = Map.get(snap.pending, t1)
             is_map(pending) and pending.remaining_count > 0
           end)

    {:ok, snap} = TaskStore.lease_retirement_snapshot(name: store2)
    pending = Map.fetch!(snap.pending, t1)
    assert pending.remaining_count > 0
    # Snapshot must not expose capability ids.
    refute inspect(snap) =~ "cap_"
  end

  test "public collision: second principal cannot select victim task_id", %{store: store} do
    assert {:ok, %{task_id: victim, reservation_token: token}} =
             TaskStore.reserve("agent_1", name: store)

    assert :ok = TaskStore.commit_recovery_marker(victim, token, name: store)

    # Second principal cannot pass victim id through Orchestration.
    assert {:error, :caller_selected_task_id_rejected} =
             Orchestration.dispatch("agent_2", "collide",
               caller_id: "attacker",
               task_id: victim,
               authorize?: false,
               task_store: TaskStore,
               name: store,
               security_module: NoopSecurity
             )

    # Forged activate rejected.
    assert {:error, :invalid_reservation_token} =
             TaskStore.activate("agent_2", "steal", victim, "badtokenbadtokenbadtoken",
               name: store
             )
  end

  test "marker and pure lease helpers are closed shapes" do
    assert {:ok, marker} = TaskControlLease.marker_new("task_m1", DateTime.utc_now())
    assert map_size(marker) == 3
    assert {:ok, ^marker} = TaskControlLease.marker_normalize(marker)
    assert {:error, :invalid_marker} = TaskControlLease.marker_normalize(Map.put(marker, "x", 1))

    ids = Map.new(TaskControlLease.kinds(), fn k -> {k, "cap_#{k}"} end)
    assert {:ok, lease} = TaskControlLease.new("task_m1", ids)
    assert map_size(lease) == 3
    assert map_size(lease["capabilities"]) == 6
  end

  test "stale recovery complete is ignored", %{store: store} do
    send(store, {:recovery_op_complete, make_ref(), {:ok, :marker_put}})
    Process.sleep(20)
    assert Process.alive?(store)
  end

  test "O(1) retire indexes replace a superseded attempt with its retry", %{store: store} do
    task_id = "task_idx_1"
    attempt_ref = make_ref()
    mon = Process.monitor(self())

    :sys.replace_state(store, fn state ->
      attempt = %{
        attempt_ref: attempt_ref,
        task_id: task_id,
        generation: 0,
        attempt_index: 0,
        phase: :terminal_revoke_set,
        member_ids: ["cap_1"],
        status: :admitting,
        completion_applied?: false,
        launcher_pid: nil,
        launcher_mon: mon,
        worker_pid: nil,
        worker_mon: nil,
        admit_timer: nil,
        worker_timer: nil,
        retry_timer: nil,
        admit_deadline_mono: 0,
        worker_deadline_mono: nil,
        security_module: NoopSecurity,
        revoke_fun: nil,
        last_error_class: nil
      }

      state
      |> Map.put(:lease_pending_retirement, %{
        task_id => %{
          task_id: task_id,
          members: %{"cap_1" => %{kind: :task_steer, id: "cap_1"}},
          exhausted: false,
          generation: 0,
          attempt_index: 0,
          retrigger_count: 0
        }
      })
      |> Map.put(:lease_retire_attempts, %{attempt_ref => attempt})
      |> Map.put(:lease_retire_task_index, %{task_id => attempt_ref})
      |> Map.put(:lease_retire_monitor_index, %{mon => {:launcher, attempt_ref}})
    end)

    send(store, {:lease_retire_admission_failed, attempt_ref, :admission_failed})
    Process.sleep(30)

    state = :sys.get_state(store)
    refute Map.has_key?(Map.get(state, :lease_retire_attempts, %{}), attempt_ref)
    refute Map.has_key?(Map.get(state, :lease_retire_monitor_index, %{}), mon)

    retry_ref = Map.fetch!(state.lease_retire_task_index, task_id)
    refute retry_ref == attempt_ref
    assert %{status: :retry_wait, task_id: ^task_id} = state.lease_retire_attempts[retry_ref]
  end

  defp unique(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() ->
        true

      attempts <= 0 ->
        false

      true ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)
    end
  end
end
