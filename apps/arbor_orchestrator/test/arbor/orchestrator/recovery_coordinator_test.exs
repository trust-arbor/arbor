defmodule Arbor.Orchestrator.RecoveryCoordinatorTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Orchestrator.RecoveryCoordinator
  alias Arbor.Orchestrator.JobRegistry

  describe "compute_graph_hash/1" do
    test "produces consistent SHA-256 hex hash" do
      source = "digraph { start -> end }"
      hash = RecoveryCoordinator.compute_graph_hash(source)

      assert is_binary(hash)
      assert String.length(hash) == 64
      # Deterministic
      assert hash == RecoveryCoordinator.compute_graph_hash(source)
    end

    test "different sources produce different hashes" do
      hash1 = RecoveryCoordinator.compute_graph_hash("digraph { a -> b }")
      hash2 = RecoveryCoordinator.compute_graph_hash("digraph { x -> y }")

      refute hash1 == hash2
    end
  end

  describe "status/0" do
    test "returns current recovery status" do
      status = RecoveryCoordinator.status()
      assert is_map(status)
      assert Map.has_key?(status, :enabled)
      assert Map.has_key?(status, :recovering)
      assert Map.has_key?(status, :recovered)
      assert Map.has_key?(status, :failed)
      assert Map.has_key?(status, :pending)
    end
  end

  describe "graph version check" do
    test "detects changed DOT source" do
      # Create a temp DOT file
      tmp_dir = System.tmp_dir!()
      dot_path = Path.join(tmp_dir, "recovery_test_#{:rand.uniform(100_000)}.dot")
      logs_root = Path.join(tmp_dir, "recovery_test_logs_#{:rand.uniform(100_000)}")

      original_source = """
      digraph Pipeline {
        start [type="transform" handler="echo"]
        end_ [type="transform" handler="echo"]
        start -> end_
      }
      """

      File.write!(dot_path, original_source)
      File.mkdir_p!(logs_root)

      original_hash = RecoveryCoordinator.compute_graph_hash(original_source)

      # Modify the file
      modified_source = """
      digraph Pipeline {
        start [type="transform" handler="echo"]
        middle [type="transform" handler="echo"]
        end_ [type="transform" handler="echo"]
        start -> middle -> end_
      }
      """

      File.write!(dot_path, modified_source)

      current_hash = RecoveryCoordinator.compute_graph_hash(File.read!(dot_path))

      # Hashes should differ
      refute original_hash == current_hash

      # Cleanup
      File.rm(dot_path)
      File.rm_rf(logs_root)
    end
  end

  describe "facade API" do
    test "list_resumable returns empty when no interrupted pipelines" do
      assert Arbor.Orchestrator.list_resumable() == []
    end

    test "resume returns :not_found for unknown run_id" do
      assert {:error, :not_found} = Arbor.Orchestrator.resume("nonexistent_run")
    end

    test "abandon returns :not_found for unknown run_id" do
      assert {:error, :not_found} = Arbor.Orchestrator.abandon("nonexistent_run")
    end

    test "resume rejects non-interrupted pipelines" do
      entry = %JobRegistry.Entry{
        pipeline_id: "run_active_1",
        run_id: "run_active_1",
        graph_id: "running_pipeline",
        started_at: DateTime.utc_now(),
        status: :running,
        completed_count: 0,
        total_nodes: 1,
        node_durations: %{},
        owner_node: node(),
        last_heartbeat: DateTime.utc_now()
      }

      Arbor.Persistence.BufferedStore.put("run_active_1", entry, name: :arbor_orchestrator_jobs)

      assert {:error, {:invalid_status, :running}} =
               Arbor.Orchestrator.resume("run_active_1")

      # Cleanup
      Arbor.Persistence.BufferedStore.delete("run_active_1",
        name: :arbor_orchestrator_jobs
      )
    end

    test "list_resumable only includes entries with checkpoints" do
      tmp_dir = System.tmp_dir!()

      # Create entry with checkpoint
      logs_with = Path.join(tmp_dir, "resumable_with_#{:rand.uniform(100_000)}")
      File.mkdir_p!(logs_with)
      File.write!(Path.join(logs_with, "checkpoint.json"), "{}")

      # Create entry without checkpoint
      logs_without = Path.join(tmp_dir, "resumable_without_#{:rand.uniform(100_000)}")
      File.mkdir_p!(logs_without)

      for {run_id, graph_id, logs} <- [
            {"run_with_cp", "with_cp", logs_with},
            {"run_without_cp", "without_cp", logs_without}
          ] do
        entry = %JobRegistry.Entry{
          pipeline_id: run_id,
          run_id: run_id,
          graph_id: graph_id,
          logs_root: logs,
          started_at: DateTime.utc_now(),
          status: :running,
          completed_count: 0,
          total_nodes: 1,
          node_durations: %{},
          owner_node: node(),
          last_heartbeat: DateTime.utc_now()
        }

        Arbor.Persistence.BufferedStore.put(run_id, entry, name: :arbor_orchestrator_jobs)
      end

      JobRegistry.mark_interrupted("run_with_cp")
      JobRegistry.mark_interrupted("run_without_cp")

      resumable = Arbor.Orchestrator.list_resumable()
      run_ids = Enum.map(resumable, & &1.run_id)

      assert "run_with_cp" in run_ids
      refute "run_without_cp" in run_ids

      # Cleanup
      File.rm_rf(logs_with)
      File.rm_rf(logs_without)
    end
  end
end
