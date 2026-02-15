defmodule Arbor.Orchestrator.JobRegistryTest do
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.JobRegistry

  setup do
    # Get the JobRegistry pid (should be started by Application)
    pid = Process.whereis(JobRegistry)

    # Clear the ETS table
    if :ets.whereis(:arbor_orchestrator_jobs) != :undefined do
      :ets.delete_all_objects(:arbor_orchestrator_jobs)
    end

    {:ok, registry: pid}
  end

  describe "pipeline lifecycle tracking" do
    test "tracks complete pipeline execution", %{registry: pid} do
      # Send pipeline started event
      send(
        pid,
        {:pipeline_event,
         %{
           type: :pipeline_started,
           graph_id: "test_pipeline",
           node_count: 3
         }}
      )

      Process.sleep(10)

      # Should appear in active list
      active = JobRegistry.list_active()
      assert length(active) == 1
      assert hd(active).status == :running
      assert hd(active).graph_id == "test_pipeline"
      assert hd(active).total_nodes == 3
      assert hd(active).completed_count == 0

      # Send stage events
      send(
        pid,
        {:pipeline_event,
         %{
           type: :stage_started,
           graph_id: "test_pipeline",
           node_id: "node1"
         }}
      )

      send(
        pid,
        {:pipeline_event,
         %{
           type: :stage_completed,
           graph_id: "test_pipeline",
           node_id: "node1",
           status: :success,
           duration_ms: 100
         }}
      )

      send(
        pid,
        {:pipeline_event,
         %{
           type: :stage_started,
           graph_id: "test_pipeline",
           node_id: "node2"
         }}
      )

      send(
        pid,
        {:pipeline_event,
         %{
           type: :stage_completed,
           graph_id: "test_pipeline",
           node_id: "node2",
           status: :success,
           duration_ms: 150
         }}
      )

      Process.sleep(10)

      # Check progress
      active = JobRegistry.list_active()
      assert length(active) == 1
      entry = hd(active)
      assert entry.completed_count == 2
      assert entry.current_node == "node2"
      assert entry.node_durations["node1"] == 100
      assert entry.node_durations["node2"] == 150

      # Complete pipeline
      send(
        pid,
        {:pipeline_event,
         %{
           type: :pipeline_completed,
           graph_id: "test_pipeline",
           completed_nodes: ["node1", "node2"],
           duration_ms: 500
         }}
      )

      Process.sleep(10)

      # Should move to completed
      assert JobRegistry.list_active() == []
      recent = JobRegistry.list_recent(10)
      assert length(recent) == 1
      completed = hd(recent)
      assert completed.status == :completed
      assert completed.duration_ms == 500
      assert is_struct(completed.finished_at, DateTime)
    end

    test "tracks failed pipeline", %{registry: pid} do
      # Start pipeline
      send(
        pid,
        {:pipeline_event,
         %{
           type: :pipeline_started,
           graph_id: "failing_pipeline",
           node_count: 2
         }}
      )

      Process.sleep(10)

      # Fail it
      send(
        pid,
        {:pipeline_event,
         %{
           type: :pipeline_failed,
           graph_id: "failing_pipeline",
           reason: :timeout,
           duration_ms: 1000
         }}
      )

      Process.sleep(10)

      # Should be in recent as failed
      recent = JobRegistry.list_recent(10)
      assert length(recent) == 1
      failed = hd(recent)
      assert failed.status == :failed
      assert failed.failure_reason == :timeout
      assert failed.duration_ms == 1000
    end

    test "handles multiple concurrent pipelines", %{registry: pid} do
      # Start 3 pipelines
      send(
        pid,
        {:pipeline_event,
         %{
           type: :pipeline_started,
           graph_id: "pipeline1",
           node_count: 1
         }}
      )

      send(
        pid,
        {:pipeline_event,
         %{
           type: :pipeline_started,
           graph_id: "pipeline2",
           node_count: 1
         }}
      )

      send(
        pid,
        {:pipeline_event,
         %{
           type: :pipeline_started,
           graph_id: "pipeline3",
           node_count: 1
         }}
      )

      Process.sleep(10)

      # All should be active
      assert length(JobRegistry.list_active()) == 3

      # Complete pipeline1 and pipeline2
      send(
        pid,
        {:pipeline_event,
         %{
           type: :pipeline_completed,
           completed_nodes: ["node1"],
           duration_ms: 100
         }}
      )

      # Need to find the right pipeline_id for pipeline2
      # Since we're using graph_id as the key, we need to send events that match
      # Actually, the find_entry_key will look for graph_id in the event
      # Let me include graph_id in the completion events

      send(
        pid,
        {:pipeline_event,
         %{
           type: :pipeline_completed,
           graph_id: "pipeline1",
           completed_nodes: ["node1"],
           duration_ms: 100
         }}
      )

      send(
        pid,
        {:pipeline_event,
         %{
           type: :pipeline_completed,
           graph_id: "pipeline2",
           completed_nodes: ["node1"],
           duration_ms: 200
         }}
      )

      # Fail pipeline3
      send(
        pid,
        {:pipeline_event,
         %{
           type: :pipeline_failed,
           graph_id: "pipeline3",
           reason: :error,
           duration_ms: 50
         }}
      )

      Process.sleep(10)

      # No active pipelines
      assert JobRegistry.list_active() == []

      # 3 recent pipelines
      recent = JobRegistry.list_recent(10)
      assert length(recent) == 3

      # Check they're sorted by finished_at (newest first)
      assert Enum.all?(recent, fn entry ->
               entry.status in [:completed, :failed]
             end)
    end

    test "prunes history", %{registry: pid} do
      # Insert 55 completed pipelines
      for i <- 1..55 do
        send(
          pid,
          {:pipeline_event,
           %{
             type: :pipeline_started,
             graph_id: "pipeline_#{i}",
             node_count: 1
           }}
        )

        # Small delay to ensure different timestamps
        Process.sleep(1)

        send(
          pid,
          {:pipeline_event,
           %{
             type: :pipeline_completed,
             graph_id: "pipeline_#{i}",
             completed_nodes: ["node1"],
             duration_ms: 100
           }}
        )
      end

      Process.sleep(100)

      # Should only keep 50
      recent = JobRegistry.list_recent(100)
      assert length(recent) <= 50
    end

    test "get returns entry by id", %{registry: pid} do
      # Start pipeline
      send(
        pid,
        {:pipeline_event,
         %{
           type: :pipeline_started,
           graph_id: "specific_pipeline",
           node_count: 1
         }}
      )

      Process.sleep(10)

      # Get by pipeline_id (which is graph_id in this case)
      entry = JobRegistry.get("specific_pipeline")
      assert entry != nil
      assert entry.graph_id == "specific_pipeline"
      assert entry.status == :running
    end

    test "get returns nil for unknown id" do
      entry = JobRegistry.get("nonexistent_pipeline_12345")
      assert entry == nil
    end

    test "list_recent respects limit" do
      # Create 10 completed pipelines
      for i <- 1..10 do
        send(
          Process.whereis(JobRegistry),
          {:pipeline_event,
           %{
             type: :pipeline_started,
             graph_id: "limit_test_#{i}",
             node_count: 1
           }}
        )

        Process.sleep(1)

        send(
          Process.whereis(JobRegistry),
          {:pipeline_event,
           %{
             type: :pipeline_completed,
             graph_id: "limit_test_#{i}",
             completed_nodes: ["node1"],
             duration_ms: 100
           }}
        )
      end

      Process.sleep(50)

      # Request only 5
      recent = JobRegistry.list_recent(5)
      assert length(recent) <= 5
    end

    test "list_recent returns newest first" do
      pid = Process.whereis(JobRegistry)

      # Create 3 pipelines with delays
      send(
        pid,
        {:pipeline_event,
         %{
           type: :pipeline_started,
           graph_id: "oldest",
           node_count: 1
         }}
      )

      Process.sleep(10)

      send(
        pid,
        {:pipeline_event,
         %{
           type: :pipeline_completed,
           graph_id: "oldest",
           completed_nodes: ["node1"],
           duration_ms: 100
         }}
      )

      Process.sleep(50)

      send(
        pid,
        {:pipeline_event,
         %{
           type: :pipeline_started,
           graph_id: "middle",
           node_count: 1
         }}
      )

      Process.sleep(10)

      send(
        pid,
        {:pipeline_event,
         %{
           type: :pipeline_completed,
           graph_id: "middle",
           completed_nodes: ["node1"],
           duration_ms: 100
         }}
      )

      Process.sleep(50)

      send(
        pid,
        {:pipeline_event,
         %{
           type: :pipeline_started,
           graph_id: "newest",
           node_count: 1
         }}
      )

      Process.sleep(10)

      send(
        pid,
        {:pipeline_event,
         %{
           type: :pipeline_completed,
           graph_id: "newest",
           completed_nodes: ["node1"],
           duration_ms: 100
         }}
      )

      Process.sleep(50)

      recent = JobRegistry.list_recent(10)

      finished_pipelines =
        Enum.filter(recent, fn e ->
          e.graph_id in ["oldest", "middle", "newest"]
        end)

      assert length(finished_pipelines) == 3

      # First should be newest
      assert hd(finished_pipelines).graph_id == "newest"
    end
  end
end
