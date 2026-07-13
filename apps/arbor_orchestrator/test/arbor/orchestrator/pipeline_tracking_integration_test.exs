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

  Shared `:arbor_pipeline_runs` is application-owned. Tests never clear the
  whole table: each test uses a collision-resistant run_id prefix, asserts
  only against its own rows, and deletes only those owned rows on cleanup.
  """

  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.Engine
  alias Arbor.Orchestrator.PipelineStatus
  alias Arbor.Orchestrator.RunState.Core, as: RunState

  @moduletag :integration

  @ets_table :arbor_pipeline_runs

  # Far-future timestamps keep owned list_recent fixtures inside the facade's
  # global sort+limit bound without clearing the shared table.
  @owned_recent_old_finished_at ~U[2999-12-31 23:58:00Z]
  @owned_recent_new_finished_at ~U[2999-12-31 23:59:00Z]
  @owned_recent_limit_base ~U[2999-12-31 23:50:00Z]

  # Static test-only statuses for exact count_by_status assertions independent
  # of foreign shared rows that may use real :running/:completed/:failed.
  @count_status_running :__pt_fixture_count_running__
  @count_status_completed :__pt_fixture_count_completed__
  @count_status_failed :__pt_fixture_count_failed__

  setup do
    ensure_pipeline_runs_table!()

    # Collision-resistant ownership prefix — never wipe shared table contents.
    run_prefix = "pt_#{System.unique_integer([:positive, :monotonic])}_"

    on_exit(fn ->
      delete_owned_pipeline_runs(run_prefix)
    end)

    {:ok, run_prefix: run_prefix}
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
    test "Engine.run writes RunState to ETS on pipeline start and completion", %{
      run_prefix: prefix
    } do
      graph = build_minimal_graph()
      run_id = owned_run_id(prefix, "ets_write")

      assert :ets.lookup(@ets_table, run_id) == []

      {:ok, _result} = Engine.run(graph, run_id: run_id)

      [{^run_id, entry}] = :ets.lookup(@ets_table, run_id)
      assert entry.status == :completed
      assert entry.graph_id == "MinimalTest"
      assert entry.run_id == run_id
      assert is_integer(entry.duration_ms)
      assert entry.last_ets_sync != nil
    end

    test "Engine.run tracks node-level progress in ETS", %{run_prefix: prefix} do
      graph = build_two_node_graph()
      run_id = owned_run_id(prefix, "node_tracking")

      {:ok, _result} = Engine.run(graph, run_id: run_id)

      [{^run_id, entry}] = :ets.lookup(@ets_table, run_id)

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
    test "returns running pipelines", %{run_prefix: prefix} do
      active_id =
        insert_ets_entry(owned_run_id(prefix, "active_1"), %{
          status: :running,
          started_at: DateTime.utc_now()
        })

      _done_id =
        insert_ets_entry(owned_run_id(prefix, "done_1"), %{
          status: :completed,
          started_at: DateTime.utc_now()
        })

      active =
        PipelineStatus.list_active()
        |> Enum.filter(&owned_run?(&1.run_id, prefix))

      assert length(active) == 1
      assert hd(active).run_id == active_id
      assert hd(active).status == :running
    end

    test "corrects status to :interrupted when spawning_pid is dead", %{run_prefix: prefix} do
      # Create a process that immediately exits — gives us a dead PID
      dead_pid = spawn(fn -> :ok end)
      Process.sleep(50)
      refute Process.alive?(dead_pid)

      orphan_id =
        insert_ets_entry(owned_run_id(prefix, "orphan_1"), %{
          status: :running,
          spawning_pid: dead_pid,
          started_at: DateTime.utc_now()
        })

      # The Facade should detect the dead PID and NOT return it as active
      active =
        PipelineStatus.list_active()
        |> Enum.filter(&owned_run?(&1.run_id, prefix))

      assert active == []

      # Direct get should show :interrupted
      entry = PipelineStatus.get(orphan_id)
      assert entry.status == :interrupted
    end

    test "returns running pipelines when spawning_pid is alive", %{run_prefix: prefix} do
      alive_id =
        insert_ets_entry(owned_run_id(prefix, "alive_1"), %{
          status: :running,
          spawning_pid: self(),
          started_at: DateTime.utc_now()
        })

      active =
        PipelineStatus.list_active()
        |> Enum.filter(&owned_run?(&1.run_id, prefix))

      assert length(active) == 1
      assert hd(active).run_id == alive_id
      assert hd(active).status == :running
    end
  end

  describe "PipelineStatus.list_recent/1" do
    test "returns completed pipelines sorted by finished_at desc", %{run_prefix: prefix} do
      # Far-future finished_at values keep owned fixtures inside list_recent/1's
      # global sort bound even when the shared table already holds many rows.
      # Never filter owned rows after a small limit — that can drop them first.
      old_id =
        insert_ets_entry(owned_run_id(prefix, "old"), %{
          status: :completed,
          finished_at: @owned_recent_old_finished_at,
          started_at: DateTime.add(@owned_recent_old_finished_at, -60, :second)
        })

      new_id =
        insert_ets_entry(owned_run_id(prefix, "new"), %{
          status: :completed,
          finished_at: @owned_recent_new_finished_at,
          started_at: DateTime.add(@owned_recent_new_finished_at, -60, :second)
        })

      recent = PipelineStatus.list_recent(limit: 2)

      assert length(recent) == 2
      assert Enum.map(recent, & &1.run_id) == [new_id, old_id]
      assert Enum.all?(recent, &owned_run?(&1.run_id, prefix))
    end

    test "respects limit option", %{run_prefix: prefix} do
      # Distinct far-future timestamps so owned order is deterministic and they
      # occupy the head of the global sort regardless of foreign shared rows.
      ids =
        for i <- 1..5 do
          finished_at = DateTime.add(@owned_recent_limit_base, i, :second)

          insert_ets_entry(owned_run_id(prefix, "limit_#{i}"), %{
            status: :completed,
            finished_at: finished_at,
            started_at: DateTime.add(finished_at, -60, :second)
          })
        end

      limited = PipelineStatus.list_recent(limit: 2)
      assert length(limited) == 2
      assert Enum.map(limited, & &1.run_id) == Enum.take(Enum.reverse(ids), 2)

      head_five = PipelineStatus.list_recent(limit: 5)
      assert length(head_five) == 5
      assert Enum.map(head_five, & &1.run_id) == Enum.reverse(ids)
      assert Enum.all?(head_five, &owned_run?(&1.run_id, prefix))
    end
  end

  describe "PipelineStatus.count_by_status/0" do
    test "groups and counts correctly", %{run_prefix: prefix} do
      # Static test-only statuses so facade counts are exact and independent of
      # foreign shared rows that may use :running/:completed/:failed.
      _ids = [
        insert_ets_entry(owned_run_id(prefix, "r1"), %{
          status: @count_status_running,
          spawning_pid: self(),
          started_at: DateTime.utc_now()
        }),
        insert_ets_entry(owned_run_id(prefix, "r2"), %{
          status: @count_status_running,
          spawning_pid: self(),
          started_at: DateTime.utc_now()
        }),
        insert_ets_entry(owned_run_id(prefix, "c1"), %{
          status: @count_status_completed,
          started_at: DateTime.utc_now()
        }),
        insert_ets_entry(owned_run_id(prefix, "f1"), %{
          status: @count_status_failed,
          started_at: DateTime.utc_now()
        })
      ]

      counts = PipelineStatus.count_by_status()

      assert counts[@count_status_running] == 2
      assert counts[@count_status_completed] == 1
      assert counts[@count_status_failed] == 1
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
    test "marks a running entry as abandoned in ETS", %{run_prefix: prefix} do
      run_id =
        insert_ets_entry(owned_run_id(prefix, "abandon_1"), %{
          status: :running,
          current_node: "bg_checks",
          started_at: DateTime.utc_now()
        })

      :ok = PipelineStatus.mark_abandoned(run_id)

      entry = PipelineStatus.get(run_id)
      assert entry.status == :abandoned
      assert entry.current_node == nil
    end
  end

  describe "fixture ownership" do
    test "cleanup removes only owned rows and leaves foreign shared rows", %{run_prefix: prefix} do
      foreign_id = "foreign_pipeline_#{System.unique_integer([:positive, :monotonic])}"
      owned_id = owned_run_id(prefix, "owned_only")

      insert_ets_entry(foreign_id, %{status: :completed, started_at: DateTime.utc_now()})
      # Register foreign cleanup before any assertion so a failure cannot leak it.
      on_exit(fn -> safe_delete_run(foreign_id) end)

      insert_ets_entry(owned_id, %{status: :completed, started_at: DateTime.utc_now()})

      assert [{^owned_id, _}] = :ets.lookup(@ets_table, owned_id)
      assert [{^foreign_id, _}] = :ets.lookup(@ets_table, foreign_id)

      # Simulate on_exit ownership cleanup for this prefix only.
      delete_owned_pipeline_runs(prefix)

      assert :ets.lookup(@ets_table, owned_id) == []
      assert [{^foreign_id, _}] = :ets.lookup(@ets_table, foreign_id)
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp ensure_pipeline_runs_table! do
    try do
      :ets.new(@ets_table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

      :ok
    rescue
      ArgumentError ->
        # Table already exists (previous test or live application owner) — leave it.
        :ok
    end
  end

  defp owned_run_id(prefix, label) when is_binary(prefix) and is_binary(label) do
    prefix <> label
  end

  defp owned_run?(run_id, prefix) when is_binary(run_id) and is_binary(prefix) do
    String.starts_with?(run_id, prefix)
  end

  defp owned_run?(_run_id, _prefix), do: false

  defp delete_owned_pipeline_runs(prefix) when is_binary(prefix) do
    try do
      case :ets.info(@ets_table) do
        :undefined ->
          :ok

        _ ->
          for {key, _entry} <- :ets.tab2list(@ets_table),
              is_binary(key) and String.starts_with?(key, prefix) do
            :ets.delete(@ets_table, key)
          end

          :ok
      end
    rescue
      _ -> :ok
    end
  end

  defp safe_delete_run(run_id) when is_binary(run_id) do
    try do
      case :ets.info(@ets_table) do
        :undefined -> :ok
        _ -> :ets.delete(@ets_table, run_id)
      end
    rescue
      _ -> :ok
    end
  end

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
    run_id
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
