defmodule Arbor.Orchestrator.RunJournalMonotonicHeartbeatTest do
  @moduledoc """
  Regression for stale process-local RunState overwriting a newer journal
  heartbeat after the Engine in-call ticker advances it.

  Sequence that previously regressed:
  1. admit/put RunState with heartbeat T0
  2. touch_heartbeat advances canonical last_heartbeat to T1
  3. put_run_state of the still-stale T0 snapshot overwrote T1

  Fix lives at the RunJournal put_run_state ownership boundary: within the
  same owner epoch (owner_node + spawning_pid), last_heartbeat is
  monotonic. A changed owner epoch must not inherit prior freshness.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Orchestrator.RunJournal
  alias Arbor.Orchestrator.RunState.Core, as: RunState

  setup do
    suffix = System.unique_integer([:positive, :monotonic])
    journal_name = :"rj_mono_hb_journal_#{suffix}"
    ets_table = :"rj_mono_hb_hot_#{suffix}"
    run_id = "mono_hb_#{suffix}"

    {:ok, journal} =
      start_supervised(
        {RunJournal,
         name: journal_name,
         ets_table: ets_table}
      )

    on_exit(fn ->
      try do
        GenServer.stop(journal, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, journal_name: journal_name, run_id: run_id, journal: journal}
  end

  test "stale put_run_state does not regress journal heartbeat for same owner epoch", %{
    journal_name: j,
    run_id: run_id
  } do
    owner = node()
    pid = self()
    t0 = ~U[2026-07-01 12:00:00.000000Z]
    t1 = ~U[2026-07-01 12:00:45.000000Z]

    stale = run_state(run_id, t0, owner, pid)

    assert :ok =
             RunJournal.admit_and_put_run_state(stale, %{}, server: j, admission: :fresh)

    assert {:ok, admitted} = RunJournal.get_record(run_id, server: j)
    assert DateTime.compare(admitted.last_heartbeat, t0) == :eq
    assert admitted.spawning_pid == pid
    assert to_string(admitted.owner_node) == to_string(owner)

    # In-call ticker path: advances canonical heartbeat while process-local
    # RunState still holds T0.
    assert :ok = RunJournal.touch_heartbeat(run_id, t1, server: j)

    assert {:ok, touched} = RunJournal.get_record(run_id, server: j)
    assert DateTime.compare(touched.last_heartbeat, t1) == :eq

    # Handler returns and Engine syncs the stale process-local snapshot.
    assert :ok = RunJournal.put_run_state(stale, %{}, server: j)

    assert {:ok, after_put} = RunJournal.get_record(run_id, server: j)

    assert DateTime.compare(after_put.last_heartbeat, t1) == :eq,
           "same-owner put_run_state must not regress last_heartbeat " <>
             "(got #{inspect(after_put.last_heartbeat)}, expected #{inspect(t1)})"
  end

  test "ownership change does not preserve prior owner heartbeat", %{
    journal_name: j,
    run_id: run_id
  } do
    owner = node()
    original_pid = self()
    t0 = ~U[2026-07-01 12:00:00.000000Z]
    t1 = ~U[2026-07-01 12:00:45.000000Z]
    # Takeover snapshot is after T0 but still older than the prior owner's T1.
    t_takeover = ~U[2026-07-01 12:00:10.000000Z]

    original = run_state(run_id, t0, owner, original_pid)

    assert :ok =
             RunJournal.admit_and_put_run_state(original, %{}, server: j, admission: :fresh)

    assert :ok = RunJournal.touch_heartbeat(run_id, t1, server: j)

    # New owner epoch: same node, different Engine spawning_pid (takeover).
    {takeover_pid, mon} =
      spawn_monitor(fn ->
        receive do
          :stop -> :ok
        end
      end)

    takeover = run_state(run_id, t_takeover, owner, takeover_pid)

    assert :ok = RunJournal.put_run_state(takeover, %{}, server: j)

    assert {:ok, after_takeover} = RunJournal.get_record(run_id, server: j)

    assert after_takeover.spawning_pid == takeover_pid

    assert DateTime.compare(after_takeover.last_heartbeat, t_takeover) == :eq,
           "changed owner epoch must publish its own heartbeat, not inherit " <>
             "prior owner freshness (got #{inspect(after_takeover.last_heartbeat)})"

    refute DateTime.compare(after_takeover.last_heartbeat, t1) == :eq

    send(takeover_pid, :stop)
    assert_receive {:DOWN, ^mon, :process, ^takeover_pid, _}, 1_000
  end

  test "same owner epoch still accepts a newer process-local heartbeat", %{
    journal_name: j,
    run_id: run_id
  } do
    owner = node()
    pid = self()
    t0 = ~U[2026-07-01 12:00:00.000000Z]
    t_local = ~U[2026-07-01 12:01:00.000000Z]

    assert :ok =
             RunJournal.admit_and_put_run_state(
               run_state(run_id, t0, owner, pid),
               %{},
               server: j,
               admission: :fresh
             )

    # Process-local RunState advanced (node-boundary touch) past journal.
    assert :ok =
             RunJournal.put_run_state(run_state(run_id, t_local, owner, pid), %{}, server: j)

    assert {:ok, record} = RunJournal.get_record(run_id, server: j)
    assert DateTime.compare(record.last_heartbeat, t_local) == :eq
  end

  defp run_state(run_id, heartbeat, owner_node, spawning_pid) do
    %RunState{
      run_id: run_id,
      pipeline_id: run_id,
      graph_id: "g_#{run_id}",
      status: :running,
      total_nodes: 3,
      completed_count: 0,
      completed_nodes: [],
      node_durations: %{},
      current_node: "n1",
      started_at: heartbeat,
      last_heartbeat: heartbeat,
      last_ets_sync: heartbeat,
      owner_node: owner_node,
      source_node: owner_node,
      spawning_pid: spawning_pid
    }
  end
end
