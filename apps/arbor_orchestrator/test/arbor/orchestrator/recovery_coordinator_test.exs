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

    test "staleness decisions are deterministic when using explicit time (via JobRegistry)" do
      # This exercises the time-threading path we added in Wave 3
      # (RecoveryCoordinator → JobRegistry.list_stale_heartbeats with explicit now).
      fixed_now = ~U[2026-05-21 12:00:00Z]

      # Insert a running entry with a very old heartbeat
      entry = %JobRegistry.Entry{
        pipeline_id: "run_time_threading_test",
        run_id: "run_time_threading_test",
        graph_id: "time_threading",
        started_at: ~U[2026-05-20 00:00:00Z],
        status: :running,
        completed_count: 0,
        total_nodes: 5,
        node_durations: %{},
        owner_node: node(),
        # very old
        last_heartbeat: ~U[2026-05-20 00:00:00Z]
      }

      Arbor.Persistence.BufferedStore.put("run_time_threading_test", entry,
        name: :arbor_orchestrator_jobs
      )

      # With a 1-hour cutoff using our fixed_now, this should be considered stale
      stale = JobRegistry.list_stale_heartbeats(60 * 60 * 1000, fixed_now)
      assert Enum.any?(stale, fn e -> e.run_id == "run_time_threading_test" end)

      # Cleanup
      Arbor.Persistence.BufferedStore.delete("run_time_threading_test",
        name: :arbor_orchestrator_jobs
      )
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

    test "staleness logic respects explicit time (via JobRegistry injection)" do
      # Exercises the Wave 3 change: JobRegistry.list_stale_heartbeats threads an
      # explicit `now` into its age calculation. We prove the *injected* time — not
      # wall-clock — drives the verdict by flipping it with the cutoff alone, while
      # `now` stays fixed. (The companion test only checks the stale side once.)
      fixed_now = ~U[2026-05-21 12:00:00Z]

      # A running entry whose last heartbeat is ~36h before fixed_now.
      entry = %JobRegistry.Entry{
        pipeline_id: "run_time_injection",
        run_id: "run_time_injection",
        graph_id: "time_injection",
        started_at: ~U[2026-05-20 00:00:00Z],
        status: :running,
        completed_count: 0,
        total_nodes: 3,
        node_durations: %{},
        owner_node: node(),
        last_heartbeat: ~U[2026-05-20 00:00:00Z]
      }

      Arbor.Persistence.BufferedStore.put("run_time_injection", entry,
        name: :arbor_orchestrator_jobs
      )

      # 1-hour cutoff against fixed_now → the 36h-old heartbeat is stale.
      stale = JobRegistry.list_stale_heartbeats(60 * 60 * 1000, fixed_now)
      assert Enum.any?(stale, &(&1.run_id == "run_time_injection"))

      # 48-hour cutoff against the SAME fixed_now → no longer stale. Only the
      # injected time makes this deterministic regardless of when the test runs.
      not_stale = JobRegistry.list_stale_heartbeats(48 * 60 * 60 * 1000, fixed_now)
      refute Enum.any?(not_stale, &(&1.run_id == "run_time_injection"))

      # Cleanup
      Arbor.Persistence.BufferedStore.delete("run_time_injection", name: :arbor_orchestrator_jobs)
    end
  end
end
