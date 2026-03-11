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

  describe "distributed pipeline fields" do
    test "pipeline_started sets owner_node and origin_trust_zone", %{registry: pid} do
      send(
        pid,
        {:pipeline_event,
         %{
           type: :pipeline_started,
           graph_id: "dist_test",
           run_id: "run_dist_1",
           node_count: 2
         }}
      )

      Process.sleep(10)

      entry = JobRegistry.get("run_dist_1")
      assert entry.owner_node == node()
      assert is_integer(entry.origin_trust_zone)
      assert entry.last_heartbeat != nil
      assert is_struct(entry.last_heartbeat, DateTime)
    end

    test "touch_heartbeat updates the heartbeat timestamp", %{registry: pid} do
      send(
        pid,
        {:pipeline_event,
         %{
           type: :pipeline_started,
           graph_id: "hb_test",
           run_id: "run_hb_1",
           node_count: 1
         }}
      )

      Process.sleep(10)

      original = JobRegistry.get("run_hb_1").last_heartbeat
      Process.sleep(10)

      JobRegistry.touch_heartbeat("run_hb_1")
      Process.sleep(10)

      updated = JobRegistry.get("run_hb_1").last_heartbeat
      assert DateTime.compare(updated, original) in [:gt, :eq]
    end

    test "list_stale_heartbeats finds pipelines with old heartbeats", %{registry: pid} do
      send(
        pid,
        {:pipeline_event,
         %{
           type: :pipeline_started,
           graph_id: "stale_test",
           run_id: "run_stale_1",
           node_count: 1
         }}
      )

      Process.sleep(10)

      # With a very small max_age, the heartbeat should be considered stale
      stale = JobRegistry.list_stale_heartbeats(0)
      assert length(stale) >= 1
      assert Enum.any?(stale, fn e -> e.run_id == "run_stale_1" end)

      # With a large max_age, nothing should be stale
      not_stale = JobRegistry.list_stale_heartbeats(999_999_999)
      assert not Enum.any?(not_stale, fn e -> e.run_id == "run_stale_1" end)
    end

    test "list_by_owner finds pipelines owned by a specific node", %{registry: pid} do
      send(
        pid,
        {:pipeline_event,
         %{
           type: :pipeline_started,
           graph_id: "owner_test",
           run_id: "run_owner_1",
           node_count: 1
         }}
      )

      Process.sleep(10)

      owned = JobRegistry.list_by_owner(node())
      assert length(owned) >= 1
      assert Enum.any?(owned, fn e -> e.run_id == "run_owner_1" end)

      # No pipelines owned by a fake node
      none = JobRegistry.list_by_owner(:"fake@node")
      assert none == []
    end

    test "claim_for_recovery succeeds on interrupted pipeline", %{registry: pid} do
      send(
        pid,
        {:pipeline_event,
         %{
           type: :pipeline_started,
           graph_id: "claim_test",
           run_id: "run_claim_1",
           node_count: 1
         }}
      )

      Process.sleep(10)

      # Must be interrupted first
      JobRegistry.mark_interrupted("run_claim_1")

      assert {:ok, claimed} = JobRegistry.claim_for_recovery("run_claim_1")
      assert claimed.status == :recovering
      assert claimed.owner_node == node()
    end

    test "claim_for_recovery fails on running pipeline", %{registry: pid} do
      send(
        pid,
        {:pipeline_event,
         %{
           type: :pipeline_started,
           graph_id: "claim_fail_test",
           run_id: "run_claim_fail_1",
           node_count: 1
         }}
      )

      Process.sleep(10)

      assert {:error, {:invalid_status, :running}} =
               JobRegistry.claim_for_recovery("run_claim_fail_1")
    end

    test "claim_for_recovery fails on already-claimed pipeline", %{registry: pid} do
      send(
        pid,
        {:pipeline_event,
         %{
           type: :pipeline_started,
           graph_id: "double_claim",
           run_id: "run_double_1",
           node_count: 1
         }}
      )

      Process.sleep(10)

      JobRegistry.mark_interrupted("run_double_1")

      # First claim succeeds
      assert {:ok, _} = JobRegistry.claim_for_recovery("run_double_1", :"other@node")

      # Second claim by a different node fails (status is now :recovering)
      assert {:error, {:invalid_status, :recovering}} =
               JobRegistry.claim_for_recovery("run_double_1", :"third@node")
    end

    test "claim_for_recovery returns not_found for unknown pipeline" do
      assert {:error, :not_found} = JobRegistry.claim_for_recovery("nonexistent_run")
    end
  end
end
