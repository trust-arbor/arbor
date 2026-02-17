defmodule Arbor.Orchestrator.EventTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Event

  @moduletag :fast

  describe "pipeline lifecycle events" do
    test "pipeline_started" do
      event = Event.pipeline_started("graph_1", logs_root: "/tmp", node_count: 5)
      assert event.type == :pipeline_started
      assert event.graph_id == "graph_1"
      assert event.logs_root == "/tmp"
      assert event.node_count == 5
    end

    test "pipeline_completed" do
      event = Event.pipeline_completed(["a", "b"], 100)
      assert event.type == :pipeline_completed
      assert event.completed_nodes == ["a", "b"]
      assert event.duration_ms == 100
    end

    test "pipeline_failed with duration" do
      event = Event.pipeline_failed(:timeout, 500)
      assert event.type == :pipeline_failed
      assert event.reason == :timeout
      assert event.duration_ms == 500
    end

    test "pipeline_failed without duration" do
      event = Event.pipeline_failed(:timeout)
      assert event.type == :pipeline_failed
      assert event.reason == :timeout
      refute Map.has_key?(event, :duration_ms)
    end

    test "pipeline_resumed" do
      event = Event.pipeline_resumed("/tmp/checkpoint.json", "node_3")
      assert event.type == :pipeline_resumed
      assert event.checkpoint == "/tmp/checkpoint.json"
      assert event.current_node == "node_3"
    end
  end

  describe "stage lifecycle events" do
    test "stage_started" do
      event = Event.stage_started("task_1")
      assert event.type == :stage_started
      assert event.node_id == "task_1"
    end

    test "stage_completed with duration" do
      event = Event.stage_completed("task_1", :success, duration_ms: 42)
      assert event.type == :stage_completed
      assert event.node_id == "task_1"
      assert event.status == :success
      assert event.duration_ms == 42
    end

    test "stage_completed without duration" do
      event = Event.stage_completed("task_1", :skipped)
      assert event.type == :stage_completed
      refute Map.has_key?(event, :duration_ms)
    end

    test "stage_failed with all opts" do
      event = Event.stage_failed("task_1", "timeout", will_retry: true, duration_ms: 100)
      assert event.type == :stage_failed
      assert event.node_id == "task_1"
      assert event.error == "timeout"
      assert event.will_retry == true
      assert event.duration_ms == 100
    end

    test "stage_failed with no opts" do
      event = Event.stage_failed("task_1", "crash")
      assert event.type == :stage_failed
      refute Map.has_key?(event, :will_retry)
      refute Map.has_key?(event, :duration_ms)
    end

    test "stage_retrying" do
      event = Event.stage_retrying("task_1", 2, 1000)
      assert event.type == :stage_retrying
      assert event.node_id == "task_1"
      assert event.attempt == 2
      assert event.delay_ms == 1000
    end

    test "stage_skipped" do
      event = Event.stage_skipped("task_1", :content_hash_match)
      assert event.type == :stage_skipped
      assert event.node_id == "task_1"
      assert event.reason == :content_hash_match
    end
  end

  describe "fidelity and checkpoint events" do
    test "fidelity_resolved" do
      event = Event.fidelity_resolved("task_1", :full, "thread_abc")
      assert event.type == :fidelity_resolved
      assert event.node_id == "task_1"
      assert event.mode == :full
      assert event.thread_id == "thread_abc"
    end

    test "checkpoint_saved" do
      event = Event.checkpoint_saved("task_1", "/tmp/checkpoint.json")
      assert event.type == :checkpoint_saved
      assert event.node_id == "task_1"
      assert event.path == "/tmp/checkpoint.json"
    end
  end

  describe "fan-out/fan-in events" do
    test "fan_out_detected" do
      event = Event.fan_out_detected("fork", 3, ["a", "b", "c"])
      assert event.type == :fan_out_detected
      assert event.node_id == "fork"
      assert event.branch_count == 3
      assert event.targets == ["a", "b", "c"]
    end

    test "fan_out_branch_resuming" do
      event = Event.fan_out_branch_resuming("branch_2", 1)
      assert event.type == :fan_out_branch_resuming
      assert event.node_id == "branch_2"
      assert event.pending_count == 1
    end

    test "fan_in_deferred" do
      event = Event.fan_in_deferred("join", ["a", "b"])
      assert event.type == :fan_in_deferred
      assert event.node_id == "join"
      assert event.waiting_for == ["a", "b"]
    end
  end

  describe "goal gate and loop control events" do
    test "goal_gate_retrying" do
      event = Event.goal_gate_retrying("retry_node")
      assert event.type == :goal_gate_retrying
      assert event.target == "retry_node"
    end

    test "loop_restart" do
      event = Event.loop_restart("task", "start")
      assert event.type == :loop_restart
      assert event.edge == %{from: "task", to: "start"}
      assert event.reason == :loop_restart_edge
    end
  end
end
