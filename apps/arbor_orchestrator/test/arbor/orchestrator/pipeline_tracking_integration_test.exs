defmodule Arbor.Orchestrator.PipelineTrackingIntegrationTest do
  @moduledoc """
  Integration tests for the Engine-owned pipeline tracking via RunState CRC
  + ETS table + PipelineStatus Facade.

  These tests verify the full lifecycle:
  - Engine creates RunState, writes to ETS on pipeline start
  - Engine updates RunState as nodes execute, syncs to ETS
  - Engine marks pipeline completed/failed, syncs final state
  - PipelineStatus Facade reads from ETS correctly
  - PID liveness check detects dead spawning processes
  - Staleness detection works

  Tests create their own ETS table to avoid conflicting with the live
  server's table. Uses a real Engine.run with a minimal DOT graph.
  """

  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.Engine
  alias Arbor.Orchestrator.PipelineStatus
  alias Arbor.Orchestrator.RunState.Core, as: RunState

  @moduletag :integration

  @ets_table :arbor_pipeline_runs

  setup do
    # Create or clear the ETS table for this test
    try do
      :ets.new(@ets_table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])
    rescue
      ArgumentError ->
        # Table already exists (from a previous test or the live server)
        :ets.delete_all_objects(@ets_table)
    end

    on_exit(fn ->
      try do
        :ets.delete_all_objects(@ets_table)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  # ===========================================================================
  # RunState.Core unit-level sanity (fast, no Engine needed)
  # ===========================================================================

  describe "RunState.Core basics" do
    test "full lifecycle: new → node_started → node_completed → mark_completed" do
      now = DateTime.utc_now()

      state =
        RunState.new("run_test", "TestGraph", 3, now: now, owner_node: node())
        |> RunState.node_started("a")
        |> RunState.node_completed("a", 10)
        |> RunState.node_started("b")
        |> RunState.node_completed("b", 20)
        |> RunState.mark_completed(30, now: now)

      assert state.status == :completed
      assert state.completed_count == 2
      assert state.completed_nodes == ["b", "a"]
      assert state.duration_ms == 30
    end

    test "to_ets_entry sanitizes failure reasons" do
      now = DateTime.utc_now()

      state =
        RunState.new("run_test", "TestGraph", 3, now: now)
        |> RunState.node_failed("bad_node", %{secret: "agent_context"})

      entry = RunState.to_ets_entry(state)
      # The detailed reason is stripped — only the node_id is kept
      assert entry.failure_reason == {:node_failed, "bad_node"}
    end
  end

  # ===========================================================================
  # ETS integration
  # ===========================================================================

  describe "ETS write/read via sync_run_state" do
    test "Engine.run writes RunState to ETS on pipeline start and completion" do
      # Use a minimal graph that completes immediately
      graph = build_minimal_graph()

      assert :ets.tab2list(@ets_table) == []

      # Run the pipeline
      {:ok, result} = Engine.run(graph, run_id: "test_ets_write_001")

      # The ETS table should have an entry
      entries = :ets.tab2list(@ets_table)
      assert length(entries) >= 1

      {key, entry} = List.last(entries)
      assert key == "test_ets_write_001"
      assert entry.status == :completed
      assert entry.graph_id == "MinimalTest"
      assert entry.run_id == "test_ets_write_001"
      assert is_integer(entry.duration_ms)
      assert entry.last_ets_sync != nil
    end

    test "Engine.run tracks node-level progress in ETS" do
      graph = build_two_node_graph()

      {:ok, _result} = Engine.run(graph, run_id: "test_node_tracking_001")

      [{_key, entry}] = :ets.lookup(@ets_table, "test_node_tracking_001")

      assert entry.status == :completed
      assert entry.completed_count >= 1
      assert is_list(entry.completed_nodes)
      assert length(entry.completed_nodes) >= 1
    end
  end

  # ===========================================================================
  # PipelineStatus Facade
  # ===========================================================================

  describe "PipelineStatus.list_active/1" do
    test "returns running pipelines" do
      insert_ets_entry("run_active_1", %{status: :running, started_at: DateTime.utc_now()})
      insert_ets_entry("run_done_1", %{status: :completed, started_at: DateTime.utc_now()})

      active = PipelineStatus.list_active()
      assert length(active) == 1
      assert hd(active).status == :running
    end

    test "corrects status to :interrupted when spawning_pid is dead" do
      # Create a process that immediately exits — gives us a dead PID
      dead_pid = spawn(fn -> :ok end)
      Process.sleep(50)
      refute Process.alive?(dead_pid)

      insert_ets_entry("run_orphan_1", %{
        status: :running,
        spawning_pid: dead_pid,
        started_at: DateTime.utc_now()
      })

      # The Facade should detect the dead PID and NOT return it as active
      active = PipelineStatus.list_active()
      assert active == []

      # Direct get should show :interrupted
      entry = PipelineStatus.get("run_orphan_1")
      assert entry.status == :interrupted
    end

    test "returns running pipelines when spawning_pid is alive" do
      insert_ets_entry("run_alive_1", %{
        status: :running,
        spawning_pid: self(),
        started_at: DateTime.utc_now()
      })

      active = PipelineStatus.list_active()
      assert length(active) == 1
      assert hd(active).status == :running
    end
  end

  describe "PipelineStatus.list_recent/1" do
    test "returns completed pipelines sorted by finished_at desc" do
      insert_ets_entry("run_old", %{
        status: :completed,
        finished_at: ~U[2026-04-12 10:00:00Z],
        started_at: ~U[2026-04-12 09:59:00Z]
      })

      insert_ets_entry("run_new", %{
        status: :completed,
        finished_at: ~U[2026-04-12 11:00:00Z],
        started_at: ~U[2026-04-12 10:59:00Z]
      })

      recent = PipelineStatus.list_recent()
      assert length(recent) == 2
      assert hd(recent).run_id == "run_new"
    end

    test "respects limit option" do
      for i <- 1..5 do
        insert_ets_entry("run_limit_#{i}", %{
          status: :completed,
          finished_at: DateTime.utc_now(),
          started_at: DateTime.utc_now()
        })
      end

      assert length(PipelineStatus.list_recent(limit: 2)) == 2
    end
  end

  describe "PipelineStatus.count_by_status/0" do
    test "groups and counts correctly" do
      insert_ets_entry("r1", %{
        status: :running,
        spawning_pid: self(),
        started_at: DateTime.utc_now()
      })

      insert_ets_entry("r2", %{
        status: :running,
        spawning_pid: self(),
        started_at: DateTime.utc_now()
      })

      insert_ets_entry("c1", %{status: :completed, started_at: DateTime.utc_now()})
      insert_ets_entry("f1", %{status: :failed, started_at: DateTime.utc_now()})

      counts = PipelineStatus.count_by_status()
      assert counts[:running] == 2
      assert counts[:completed] == 1
      assert counts[:failed] == 1
    end
  end

  describe "PipelineStatus.stale?/1" do
    test "detects stale active entries" do
      old_sync = DateTime.add(DateTime.utc_now(), -120, :second)

      entry = %{
        status: :running,
        last_ets_sync: old_sync
      }

      assert PipelineStatus.stale?(entry)
    end

    test "not stale when recently synced" do
      entry = %{
        status: :running,
        last_ets_sync: DateTime.utc_now()
      }

      refute PipelineStatus.stale?(entry)
    end

    test "completed entries are never stale" do
      old_sync = DateTime.add(DateTime.utc_now(), -120, :second)

      entry = %{
        status: :completed,
        last_ets_sync: old_sync
      }

      refute PipelineStatus.stale?(entry)
    end
  end

  describe "PipelineStatus.mark_abandoned/1" do
    test "marks a running entry as abandoned in ETS" do
      insert_ets_entry("run_abandon_1", %{
        status: :running,
        current_node: "bg_checks",
        started_at: DateTime.utc_now()
      })

      :ok = PipelineStatus.mark_abandoned("run_abandon_1")

      entry = PipelineStatus.get("run_abandon_1")
      assert entry.status == :abandoned
      assert entry.current_node == nil
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp insert_ets_entry(run_id, attrs) do
    entry =
      %{
        run_id: run_id,
        pipeline_id: run_id,
        graph_id: "Test",
        status: :running,
        total_nodes: 5,
        completed_count: 0,
        completed_nodes: [],
        current_node: nil,
        node_durations: %{},
        started_at: nil,
        finished_at: nil,
        duration_ms: nil,
        failure_reason: nil,
        owner_node: node(),
        source_node: node(),
        spawning_pid: nil,
        last_heartbeat: DateTime.utc_now(),
        last_ets_sync: DateTime.utc_now()
      }
      |> Map.merge(attrs)

    :ets.insert(@ets_table, {run_id, entry})
  end

  # Build a minimal DOT graph that completes in one step
  defp build_minimal_graph do
    dot = """
    digraph MinimalTest {
      start [shape=Mdiamond]
      done [shape=Msquare]
      start -> done
    }
    """

    {:ok, graph} = Arbor.Orchestrator.Dot.Parser.parse(dot)
    graph
  end

  # Build a graph with two real nodes
  defp build_two_node_graph do
    dot = """
    digraph TwoNodeTest {
      start [shape=Mdiamond]
      work [type="exec" target="noop"]
      done [shape=Msquare]
      start -> work -> done
    }
    """

    {:ok, graph} = Arbor.Orchestrator.Dot.Parser.parse(dot)
    graph
  end
end
