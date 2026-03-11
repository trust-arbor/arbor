defmodule Arbor.Orchestrator.JobRegistryTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Orchestrator.JobRegistry

  setup do
    # Get the JobRegistry pid (should be started by Application)
    pid = Process.whereis(JobRegistry)

    # Clear the store
    case Arbor.Persistence.BufferedStore.list(name: :arbor_orchestrator_jobs) do
      {:ok, keys} ->
        Enum.each(keys, fn key ->
          Arbor.Persistence.BufferedStore.delete(key, name: :arbor_orchestrator_jobs)
        end)

      _ ->
        :ok
    end

    {:ok, registry: pid}
  end

  describe "pipeline lifecycle tracking" do
    test "tracks complete pipeline execution", %{registry: pid} do
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

      active = JobRegistry.list_active()
      assert length(active) == 1
      assert hd(active).status == :running
      assert hd(active).graph_id == "test_pipeline"
      assert hd(active).total_nodes == 3
      assert hd(active).completed_count == 0

      send(
        pid,
        {:pipeline_event, %{type: :stage_started, graph_id: "test_pipeline", node_id: "node1"}}
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
        {:pipeline_event, %{type: :stage_started, graph_id: "test_pipeline", node_id: "node2"}}
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

      active = JobRegistry.list_active()
      assert length(active) == 1
      entry = hd(active)
      assert entry.completed_count == 2
      assert entry.current_node == "node2"
      assert entry.node_durations["node1"] == 100
      assert entry.node_durations["node2"] == 150

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

      assert JobRegistry.list_active() == []
      recent = JobRegistry.list_recent(10)
      assert length(recent) == 1
      completed = hd(recent)
      assert completed.status == :completed
      assert completed.duration_ms == 500
      assert is_struct(completed.finished_at, DateTime)
    end

    test "tracks failed pipeline", %{registry: pid} do
      send(
        pid,
        {:pipeline_event, %{type: :pipeline_started, graph_id: "failing_pipeline", node_count: 2}}
      )

      Process.sleep(10)

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

      recent = JobRegistry.list_recent(10)
      assert length(recent) == 1
      failed = hd(recent)
      assert failed.status == :failed
      assert failed.failure_reason == :timeout
      assert failed.duration_ms == 1000
    end

    test "get returns entry by id", %{registry: pid} do
      send(
        pid,
        {:pipeline_event,
         %{type: :pipeline_started, graph_id: "specific_pipeline", node_count: 1}}
      )

      Process.sleep(10)

      entry = JobRegistry.get("specific_pipeline")
      assert entry != nil
      assert entry.graph_id == "specific_pipeline"
      assert entry.status == :running
    end

    test "get returns nil for unknown id" do
      assert JobRegistry.get("nonexistent_pipeline_12345") == nil
    end

    test "tracks run_id and graph_hash", %{registry: pid} do
      send(
        pid,
        {:pipeline_event,
         %{
           type: :pipeline_started,
           graph_id: "hashed_pipeline",
           run_id: "run_test_123",
           graph_hash: "abc123hash",
           dot_source_path: "/tmp/test.dot",
           logs_root: "/tmp/test_logs",
           node_count: 2
         }}
      )

      Process.sleep(10)

      entry = JobRegistry.get("run_test_123")
      assert entry != nil
      assert entry.run_id == "run_test_123"
      assert entry.graph_hash == "abc123hash"
      assert entry.dot_source_path == "/tmp/test.dot"
      assert entry.logs_root == "/tmp/test_logs"
    end
  end

  describe "recovery status management" do
    test "mark_interrupted changes status", %{registry: pid} do
      send(
        pid,
        {:pipeline_event,
         %{
           type: :pipeline_started,
           graph_id: "interrupt_test",
           run_id: "run_interrupt_1",
           node_count: 1
         }}
      )

      Process.sleep(10)

      assert JobRegistry.get("run_interrupt_1").status == :running

      JobRegistry.mark_interrupted("run_interrupt_1")

      entry = JobRegistry.get("run_interrupt_1")
      assert entry.status == :interrupted
      assert [entry] == JobRegistry.list_interrupted()
    end

    test "mark_abandoned changes status", %{registry: pid} do
      send(
        pid,
        {:pipeline_event,
         %{
           type: :pipeline_started,
           graph_id: "abandon_test",
           run_id: "run_abandon_1",
           node_count: 1
         }}
      )

      Process.sleep(10)

      JobRegistry.mark_abandoned("run_abandon_1")

      entry = JobRegistry.get("run_abandon_1")
      assert entry.status == :abandoned
      assert entry.finished_at != nil
    end

    test "mark_recovering changes status", %{registry: pid} do
      send(
        pid,
        {:pipeline_event,
         %{
           type: :pipeline_started,
           graph_id: "recover_test",
           run_id: "run_recover_1",
           node_count: 1
         }}
      )

      Process.sleep(10)

      JobRegistry.mark_recovering("run_recover_1")

      entry = JobRegistry.get("run_recover_1")
      assert entry.status == :recovering
    end
  end
end
