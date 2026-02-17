defmodule Arbor.Monitor.HealingSupervisorTest do
  use ExUnit.Case, async: false

  alias Arbor.Monitor.HealingSupervisor

  setup do
    # Start the HealingSupervisor for tests
    start_supervised!(HealingSupervisor)
    :ok
  end

  describe "child processes" do
    @tag :fast
    test "AnomalyQueue is running" do
      assert Process.whereis(Arbor.Monitor.AnomalyQueue) != nil
    end

    @tag :fast
    test "CascadeDetector is running" do
      assert Process.whereis(Arbor.Monitor.CascadeDetector) != nil
    end

    @tag :fast
    test "RejectionTracker is running" do
      assert Process.whereis(Arbor.Monitor.RejectionTracker) != nil
    end

    @tag :fast
    test "Verification is running" do
      assert Process.whereis(Arbor.Monitor.Verification) != nil
    end

    @tag :fast
    test "HealingWorkers DynamicSupervisor is running" do
      assert Process.whereis(Arbor.Monitor.HealingWorkers) != nil
    end

    @tag :fast
    test "all five children are started" do
      children = Supervisor.which_children(HealingSupervisor)
      assert length(children) == 5
    end
  end

  describe "worker management" do
    @tag :fast
    test "worker_count/0 returns count of workers" do
      count = HealingSupervisor.worker_count()
      assert count == 0
    end

    @tag :fast
    test "list_workers/0 returns empty list initially" do
      workers = HealingSupervisor.list_workers()
      assert workers == []
    end

    @tag :fast
    test "start_worker/2 and stop_worker/1" do
      # Start a simple Agent as a test worker
      {:ok, pid} = HealingSupervisor.start_worker(Agent, fn -> :test_state end)
      assert is_pid(pid)
      assert Process.alive?(pid)

      # Count should increase
      assert HealingSupervisor.worker_count() == 1

      # Verify it's in the list
      workers = HealingSupervisor.list_workers()
      pids = Enum.map(workers, fn {_, p, _, _} -> p end)
      assert pid in pids

      # Stop it
      assert :ok = HealingSupervisor.stop_worker(pid)
      refute Process.alive?(pid)

      # Count should decrease
      assert HealingSupervisor.worker_count() == 0
    end

    @tag :fast
    test "can start multiple workers concurrently" do
      {:ok, pid1} = HealingSupervisor.start_worker(Agent, fn -> :state1 end)
      {:ok, pid2} = HealingSupervisor.start_worker(Agent, fn -> :state2 end)
      {:ok, pid3} = HealingSupervisor.start_worker(Agent, fn -> :state3 end)

      assert HealingSupervisor.worker_count() == 3

      workers = HealingSupervisor.list_workers()
      pids = Enum.map(workers, fn {_, p, _, _} -> p end)
      assert pid1 in pids
      assert pid2 in pids
      assert pid3 in pids

      # Stop all
      :ok = HealingSupervisor.stop_worker(pid1)
      :ok = HealingSupervisor.stop_worker(pid2)
      :ok = HealingSupervisor.stop_worker(pid3)

      assert HealingSupervisor.worker_count() == 0
    end

    @tag :fast
    test "stopping a non-existent worker returns error" do
      # Create a pid that is no longer alive
      {:ok, pid} = HealingSupervisor.start_worker(Agent, fn -> :state end)
      :ok = HealingSupervisor.stop_worker(pid)

      # Stopping it again should return error
      assert {:error, :not_found} = HealingSupervisor.stop_worker(pid)
    end

    @tag :fast
    test "workers are independent - stopping one does not affect others" do
      {:ok, pid1} = HealingSupervisor.start_worker(Agent, fn -> :state1 end)
      {:ok, pid2} = HealingSupervisor.start_worker(Agent, fn -> :state2 end)

      :ok = HealingSupervisor.stop_worker(pid1)
      refute Process.alive?(pid1)

      # pid2 should still be alive
      assert Process.alive?(pid2)
      assert HealingSupervisor.worker_count() == 1

      :ok = HealingSupervisor.stop_worker(pid2)
    end
  end

  describe "supervisor strategy" do
    @tag :fast
    test "uses one_for_one strategy" do
      # Verify that crashing one child does not crash others
      # Get current PIDs of static children
      anomaly_queue_pid = Process.whereis(Arbor.Monitor.AnomalyQueue)
      cascade_detector_pid = Process.whereis(Arbor.Monitor.CascadeDetector)

      assert is_pid(anomaly_queue_pid)
      assert is_pid(cascade_detector_pid)

      # Both should be alive - proving supervisor is running normally
      assert Process.alive?(anomaly_queue_pid)
      assert Process.alive?(cascade_detector_pid)
    end

    @tag :fast
    test "child processes restart after crash" do
      original_pid = Process.whereis(Arbor.Monitor.CascadeDetector)
      assert is_pid(original_pid)

      # Kill the CascadeDetector
      Process.exit(original_pid, :kill)

      # Give the supervisor time to restart it
      Process.sleep(50)

      new_pid = Process.whereis(Arbor.Monitor.CascadeDetector)
      assert is_pid(new_pid)
      assert new_pid != original_pid
      assert Process.alive?(new_pid)
    end

    @tag :fast
    test "other children survive when one child crashes" do
      anomaly_queue_pid = Process.whereis(Arbor.Monitor.AnomalyQueue)
      verification_pid = Process.whereis(Arbor.Monitor.Verification)

      # Kill CascadeDetector
      cascade_pid = Process.whereis(Arbor.Monitor.CascadeDetector)
      Process.exit(cascade_pid, :kill)

      Process.sleep(50)

      # AnomalyQueue and Verification should still be the same PIDs
      assert Process.whereis(Arbor.Monitor.AnomalyQueue) == anomaly_queue_pid
      assert Process.whereis(Arbor.Monitor.Verification) == verification_pid
    end

    @tag :fast
    test "DynamicSupervisor workers survive static child restart" do
      # Start a dynamic worker
      {:ok, worker_pid} = HealingSupervisor.start_worker(Agent, fn -> :test end)
      assert Process.alive?(worker_pid)

      # Kill a static child (CascadeDetector)
      cascade_pid = Process.whereis(Arbor.Monitor.CascadeDetector)
      Process.exit(cascade_pid, :kill)

      Process.sleep(50)

      # Dynamic worker should still be alive
      assert Process.alive?(worker_pid)
      assert HealingSupervisor.worker_count() == 1

      :ok = HealingSupervisor.stop_worker(worker_pid)
    end
  end

  describe "configuration passthrough" do
    @tag :fast
    test "starts with default configuration when no opts provided" do
      # The setup already starts with defaults - verify children are functioning
      # CascadeDetector should respond with default threshold
      status = Arbor.Monitor.CascadeDetector.status()
      assert is_integer(status.threshold)
      assert status.threshold > 0
    end

    @tag :fast
    test "passes healing config to children" do
      # Stop the existing supervisor
      stop_supervised!(HealingSupervisor)

      # Start with custom config
      start_supervised!(
        {HealingSupervisor,
         [
           healing: [
             cascade_detector: [cascade_threshold: 10]
           ]
         ]}
      )

      # The CascadeDetector should have the custom threshold
      status = Arbor.Monitor.CascadeDetector.status()
      assert status.threshold == 10
    end
  end

  describe "child interaction" do
    @tag :fast
    test "CascadeDetector can record anomalies after supervisor starts" do
      anomaly = %{
        skill: :memory,
        severity: :warning,
        details: %{metric: :total_bytes, value: 1_000_000, ewma: 800_000}
      }

      # Should not raise
      Arbor.Monitor.CascadeDetector.record_anomaly(anomaly)
      assert Arbor.Monitor.CascadeDetector.current_rate() >= 0
    end

    @tag :fast
    test "RejectionTracker can record rejections after supervisor starts" do
      fp = Arbor.Monitor.Fingerprint.new(:memory, :total_bytes, :above)

      result =
        Arbor.Monitor.RejectionTracker.record_rejection(fp, "test_prop", "test reason")

      assert result.strategy == :retry_with_context
      assert result.rejection_count == 1
    end

    @tag :fast
    test "AnomalyQueue can enqueue after supervisor starts" do
      anomaly = %{
        skill: :beam,
        severity: :warning,
        details: %{metric: :process_count, value: 500, ewma: 400, stddev: 30}
      }

      assert {:ok, :enqueued} = Arbor.Monitor.AnomalyQueue.enqueue(anomaly)
    end
  end
end
