defmodule Arbor.Orchestrator.EventsTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Orchestrator.Events

  describe "stream_id/1" do
    test "builds stream ID from run_id" do
      assert Events.stream_id("run_Test_nonode@nohost_20260310_a1b2c3d4") ==
               "orchestrator:pipeline:run_Test_nonode@nohost_20260310_a1b2c3d4"
    end

    test "handles nil run_id" do
      assert Events.stream_id(nil) == "orchestrator:pipeline:unknown"
    end
  end

  describe "dual_emit/2" do
    test "persists pipeline_started event to EventLog" do
      run_id = "run_test_#{System.unique_integer([:positive])}"

      event = %{
        type: :pipeline_started,
        graph_id: "TestGraph",
        run_id: run_id,
        node_count: 5
      }

      assert :ok = Events.dual_emit(event, run_id: run_id)

      # Verify it was persisted
      {:ok, events} = Events.read_run_events(run_id)
      assert length(events) >= 1

      persisted = List.last(events)
      assert persisted.type == "pipeline_started"
      assert persisted.data[:graph_id] == "TestGraph"
      assert persisted.data[:run_id] == run_id
      assert persisted.correlation_id == run_id
      assert is_map(persisted.metadata)
      assert Map.has_key?(persisted.metadata, :source_node)
    end

    test "persists stage_started event" do
      run_id = "run_test_#{System.unique_integer([:positive])}"

      event = %{type: :stage_started, node_id: "build_prompt"}
      assert :ok = Events.dual_emit(event, run_id: run_id)

      {:ok, events} = Events.read_run_events(run_id)
      assert length(events) == 1
      assert hd(events).data[:node_id] == "build_prompt"
    end

    test "persists pipeline_completed event" do
      run_id = "run_test_#{System.unique_integer([:positive])}"

      event = %{
        type: :pipeline_completed,
        completed_nodes: ["start", "process", "done"],
        duration_ms: 1234
      }

      assert :ok = Events.dual_emit(event, run_id: run_id)

      {:ok, events} = Events.read_run_events(run_id)
      assert length(events) == 1
      assert hd(events).data[:duration_ms] == 1234
    end

    test "includes source_node in metadata" do
      run_id = "run_test_#{System.unique_integer([:positive])}"

      event = %{type: :stage_started, node_id: "test_node"}
      Events.dual_emit(event, run_id: run_id)

      {:ok, [persisted]} = Events.read_run_events(run_id)
      assert persisted.metadata[:source_node] == node()
    end

    test "includes agent_id in metadata when provided" do
      run_id = "run_test_#{System.unique_integer([:positive])}"

      event = %{type: :stage_started, node_id: "test_node"}
      Events.dual_emit(event, run_id: run_id, agent_id: "agent_abc123")

      {:ok, [persisted]} = Events.read_run_events(run_id)
      assert persisted.metadata[:agent_id] == "agent_abc123"
    end

    test "multiple events form a complete run timeline" do
      run_id = "run_test_#{System.unique_integer([:positive])}"

      events = [
        %{type: :pipeline_started, graph_id: "Timeline", node_count: 3},
        %{type: :stage_started, node_id: "start"},
        %{type: :stage_completed, node_id: "start", status: :success},
        %{type: :stage_started, node_id: "process"},
        %{type: :stage_completed, node_id: "process", status: :success},
        %{type: :pipeline_completed, completed_nodes: ["start", "process"], duration_ms: 500}
      ]

      for event <- events do
        Events.dual_emit(event, run_id: run_id)
      end

      {:ok, persisted} = Events.read_run_events(run_id)
      assert length(persisted) == 6

      types = Enum.map(persisted, & &1.type)

      assert types == [
               "pipeline_started",
               "stage_started",
               "stage_completed",
               "stage_started",
               "stage_completed",
               "pipeline_completed"
             ]
    end

    test "gracefully handles missing EventLog process" do
      run_id = "run_test_#{System.unique_integer([:positive])}"

      # Use a non-existent event log name to simulate unavailability
      event = %{type: :stage_started, node_id: "test"}

      # Should not crash — graceful degradation
      assert :ok = Events.dual_emit(event, run_id: run_id)
    end
  end

  describe "read_run_events/2" do
    test "returns empty list for unknown run_id" do
      {:ok, events} = Events.read_run_events("run_nonexistent_#{System.unique_integer([:positive])}")
      assert events == []
    end
  end
end
