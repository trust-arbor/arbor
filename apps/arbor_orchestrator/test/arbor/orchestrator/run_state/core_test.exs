defmodule Arbor.Orchestrator.RunState.CoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.RunState.Core

  @moduletag :fast

  @now ~U[2026-04-12 14:00:00Z]

  defp new_state(opts \\ []) do
    Core.new(
      Keyword.get(opts, :run_id, "run_test_001"),
      Keyword.get(opts, :graph_id, "Heartbeat"),
      Keyword.get(opts, :total_nodes, 19),
      now: Keyword.get(opts, :now, @now),
      owner_node: :"test@localhost",
      source_node: :"test@localhost",
      spawning_pid: self()
    )
  end

  # ===========================================================================
  # Construct
  # ===========================================================================

  describe "new/4" do
    test "creates a running state with correct defaults" do
      state = new_state()

      assert state.run_id == "run_test_001"
      assert state.graph_id == "Heartbeat"
      assert state.pipeline_id == "run_test_001"
      assert state.status == :running
      assert state.total_nodes == 19
      assert state.completed_count == 0
      assert state.completed_nodes == []
      assert state.current_node == nil
      assert state.node_durations == %{}
      assert state.started_at == @now
      assert state.finished_at == nil
      assert state.duration_ms == nil
      assert state.failure_reason == nil
      assert state.last_heartbeat == @now
    end

    test "accepts a separate pipeline_id" do
      state = Core.new("run_1", "Graph", 5, now: @now, pipeline_id: "custom_pipeline")
      assert state.pipeline_id == "custom_pipeline"
    end

    test "defaults pipeline_id to run_id" do
      state = Core.new("run_1", "Graph", 5, now: @now)
      assert state.pipeline_id == "run_1"
    end
  end

  # ===========================================================================
  # Reduce — node-level transitions
  # ===========================================================================

  describe "node_started/2" do
    test "sets current_node when running" do
      state = new_state() |> Core.node_started("bg_checks")
      assert state.current_node == "bg_checks"
      assert state.status == :running
    end

    test "ignores when not running" do
      state = new_state() |> Core.mark_completed(100) |> Core.node_started("x")
      assert state.current_node == nil
    end
  end

  describe "node_completed/3" do
    test "increments completed count and records duration" do
      state =
        new_state()
        |> Core.node_started("bg_checks")
        |> Core.node_completed("bg_checks", 42)

      assert state.completed_count == 1
      assert state.completed_nodes == ["bg_checks"]
      assert state.node_durations == %{"bg_checks" => 42}
      assert state.current_node == nil
    end

    test "accumulates multiple completed nodes" do
      state =
        new_state()
        |> Core.node_started("a")
        |> Core.node_completed("a", 10)
        |> Core.node_started("b")
        |> Core.node_completed("b", 20)
        |> Core.node_started("c")
        |> Core.node_completed("c", 30)

      assert state.completed_count == 3
      assert length(state.completed_nodes) == 3
      assert state.node_durations == %{"a" => 10, "b" => 20, "c" => 30}
    end

    test "ignores when not running" do
      state = new_state() |> Core.mark_abandoned() |> Core.node_completed("x", 10)
      assert state.completed_count == 0
    end
  end

  describe "node_failed/3" do
    test "records failure reason with node_id" do
      state = new_state() |> Core.node_failed("bg_checks", :timeout)

      assert state.current_node == "bg_checks"
      assert state.failure_reason == {:node_failed, "bg_checks", :timeout}
      assert state.status == :running
    end
  end

  # ===========================================================================
  # Reduce — pipeline-level transitions
  # ===========================================================================

  describe "mark_completed/3" do
    test "transitions to :completed with duration and finished_at" do
      later = ~U[2026-04-12 14:00:05Z]

      state =
        new_state()
        |> Core.node_started("a")
        |> Core.node_completed("a", 100)
        |> Core.mark_completed(5000, now: later)

      assert state.status == :completed
      assert state.duration_ms == 5000
      assert state.finished_at == later
      assert state.current_node == nil
    end

    test "only transitions from :running" do
      state = new_state() |> Core.mark_abandoned() |> Core.mark_completed(100)
      assert state.status == :abandoned
    end
  end

  describe "mark_failed/4" do
    test "transitions to :failed with reason" do
      state = new_state() |> Core.mark_failed(:timeout, 3000, now: ~U[2026-04-12 14:00:03Z])

      assert state.status == :failed
      assert state.failure_reason == :timeout
      assert state.duration_ms == 3000
      assert state.finished_at == ~U[2026-04-12 14:00:03Z]
    end

    test "can fail from :suspended" do
      state =
        new_state()
        |> Core.mark_suspended(:awaiting_capability)
        |> Core.mark_failed(:denied, 1000)

      assert state.status == :failed
    end
  end

  describe "mark_abandoned/1" do
    test "transitions from :running" do
      state = new_state() |> Core.mark_abandoned()
      assert state.status == :abandoned
      assert state.current_node == nil
    end

    test "transitions from :interrupted" do
      state = new_state() |> Core.mark_interrupted() |> Core.mark_abandoned()
      assert state.status == :abandoned
    end

    test "transitions from :suspended" do
      state = new_state() |> Core.mark_suspended(:reason) |> Core.mark_abandoned()
      assert state.status == :abandoned
    end

    test "does not transition from :completed" do
      state = new_state() |> Core.mark_completed(100) |> Core.mark_abandoned()
      assert state.status == :completed
    end
  end

  describe "mark_interrupted/1" do
    test "transitions from :running" do
      state = new_state() |> Core.mark_interrupted()
      assert state.status == :interrupted
    end
  end

  describe "mark_suspended/2" do
    test "transitions from :running with reason" do
      state = new_state() |> Core.mark_suspended(:awaiting_approval)
      assert state.status == :suspended
      assert state.failure_reason == :awaiting_approval
    end
  end

  describe "mark_delegated/2" do
    test "transitions from :running with target node" do
      state = new_state() |> Core.mark_delegated(:"node_b@remote")
      assert state.status == :delegated
      assert state.failure_reason == {:delegated_to, :"node_b@remote"}
    end
  end

  describe "mark_degraded/1" do
    test "transitions from :running" do
      state = new_state() |> Core.mark_degraded()
      assert state.status == :degraded
    end
  end

  describe "resume/1" do
    test "resumes from :suspended" do
      state = new_state() |> Core.mark_suspended(:reason) |> Core.resume()
      assert state.status == :running
      assert state.failure_reason == nil
    end

    test "resumes from :interrupted" do
      state = new_state() |> Core.mark_interrupted() |> Core.resume()
      assert state.status == :running
    end

    test "does not resume from :completed" do
      state = new_state() |> Core.mark_completed(100) |> Core.resume()
      assert state.status == :completed
    end
  end

  describe "touch_heartbeat/2" do
    test "updates the heartbeat timestamp" do
      later = ~U[2026-04-12 14:01:00Z]
      state = new_state() |> Core.touch_heartbeat(later)
      assert state.last_heartbeat == later
    end
  end

  describe "mark_synced/2" do
    test "records the ETS sync timestamp" do
      later = ~U[2026-04-12 14:00:01Z]
      state = new_state() |> Core.mark_synced(later)
      assert state.last_ets_sync == later
    end
  end

  # ===========================================================================
  # Convert
  # ===========================================================================

  describe "to_ets_entry/1" do
    test "returns a map with all metadata fields" do
      entry =
        new_state()
        |> Core.node_started("a")
        |> Core.node_completed("a", 42)
        |> Core.mark_completed(5000, now: ~U[2026-04-12 14:00:05Z])
        |> Core.to_ets_entry()

      assert is_map(entry)
      assert entry.status == :completed
      assert entry.completed_count == 1
      assert entry.completed_nodes == ["a"]
      assert entry.run_id == "run_test_001"
      assert entry.graph_id == "Heartbeat"
      assert entry.duration_ms == 5000
      assert entry.spawning_pid == self()
    end

    test "sanitizes node_failed reasons (strips the detailed reason)" do
      entry =
        new_state()
        |> Core.node_failed("bg_checks", %{some: "sensitive_context"})
        |> Core.to_ets_entry()

      assert entry.failure_reason == {:node_failed, "bg_checks"}
    end

    test "sanitizes unrecognized failure reasons to :redacted" do
      state = %{new_state() | failure_reason: %{sensitive: "data", agent_goals: ["secret"]}}
      entry = Core.to_ets_entry(state)
      assert entry.failure_reason == :redacted
    end

    test "preserves atom and string failure reasons" do
      state = %{new_state() | failure_reason: :max_steps_exceeded}
      assert Core.to_ets_entry(state).failure_reason == :max_steps_exceeded

      state = %{new_state() | failure_reason: "timeout after 30s"}
      assert Core.to_ets_entry(state).failure_reason == "timeout after 30s"
    end

    test "completed_nodes are in execution order (reversed from internal list)" do
      entry =
        new_state()
        |> Core.node_started("a")
        |> Core.node_completed("a", 10)
        |> Core.node_started("b")
        |> Core.node_completed("b", 20)
        |> Core.to_ets_entry()

      assert entry.completed_nodes == ["a", "b"]
    end
  end

  describe "show_progress/1" do
    test "shows node count and current node" do
      state =
        new_state()
        |> Core.node_started("bg_checks")
        |> Core.node_completed("bg_checks", 10)
        |> Core.node_started("select_mode")

      assert Core.show_progress(state) == "1/19 nodes, current: select_mode"
    end

    test "shows just count when no current node" do
      state = new_state()
      assert Core.show_progress(state) == "0/19 nodes"
    end
  end

  # ===========================================================================
  # Queries
  # ===========================================================================

  describe "active?/1" do
    test "true for :running" do
      assert Core.active?(new_state())
    end

    test "true for :suspended" do
      assert Core.active?(new_state() |> Core.mark_suspended(:reason))
    end

    test "true for :degraded" do
      assert Core.active?(new_state() |> Core.mark_degraded())
    end

    test "false for :completed" do
      refute Core.active?(new_state() |> Core.mark_completed(100))
    end

    test "false for :failed" do
      refute Core.active?(new_state() |> Core.mark_failed(:err, 100))
    end

    test "false for :abandoned" do
      refute Core.active?(new_state() |> Core.mark_abandoned())
    end
  end

  describe "terminal?/1" do
    test "true for :completed, :failed, :abandoned" do
      assert Core.terminal?(new_state() |> Core.mark_completed(100))
      assert Core.terminal?(new_state() |> Core.mark_failed(:err, 100))
      assert Core.terminal?(new_state() |> Core.mark_abandoned())
    end

    test "false for :running, :suspended, :interrupted" do
      refute Core.terminal?(new_state())
      refute Core.terminal?(new_state() |> Core.mark_suspended(:reason))
      refute Core.terminal?(new_state() |> Core.mark_interrupted())
    end
  end

  describe "stale?/3" do
    test "true when heartbeat is older than threshold" do
      state = new_state(now: ~U[2026-04-12 14:00:00Z])
      later = ~U[2026-04-12 14:02:00Z]
      assert Core.stale?(state, 60_000, later)
    end

    test "false when heartbeat is recent" do
      state = new_state(now: ~U[2026-04-12 14:00:00Z])
      later = ~U[2026-04-12 14:00:30Z]
      refute Core.stale?(state, 60_000, later)
    end
  end

  # ===========================================================================
  # Pipeline composition (full lifecycle)
  # ===========================================================================

  describe "full lifecycle pipeline" do
    test "running → node executions → completed" do
      result =
        new_state()
        |> Core.node_started("start")
        |> Core.node_completed("start", 1)
        |> Core.node_started("bg_checks")
        |> Core.node_completed("bg_checks", 42)
        |> Core.node_started("select_mode")
        |> Core.node_completed("select_mode", 15)
        |> Core.mark_completed(5000, now: ~U[2026-04-12 14:00:05Z])

      assert result.status == :completed
      assert result.completed_count == 3
      assert result.duration_ms == 5000

      summary = Core.show_summary(result)
      assert summary.status == :completed
      assert summary.progress == "3/19 nodes"
    end

    test "running → suspended → resumed → completed" do
      result =
        new_state()
        |> Core.node_started("a")
        |> Core.node_completed("a", 10)
        |> Core.mark_suspended(:awaiting_approval)
        |> Core.resume()
        |> Core.node_started("b")
        |> Core.node_completed("b", 20)
        |> Core.mark_completed(3000)

      assert result.status == :completed
      assert result.completed_count == 2
    end

    test "running → interrupted → resumed → completed" do
      result =
        new_state()
        |> Core.mark_interrupted()
        |> Core.resume()
        |> Core.node_started("a")
        |> Core.node_completed("a", 10)
        |> Core.mark_completed(1000)

      assert result.status == :completed
    end
  end
end
