defmodule Arbor.Monitor.HealingSupervisorTest do
  use ExUnit.Case, async: false

  alias Arbor.Monitor.HealingSupervisor

  setup do
    # Start the HealingSupervisor for tests
    start_supervised!(HealingSupervisor)
    :ok
  end

  describe "child processes" do
    test "AnomalyQueue is running" do
      assert Process.whereis(Arbor.Monitor.AnomalyQueue) != nil
    end

    test "CascadeDetector is running" do
      assert Process.whereis(Arbor.Monitor.CascadeDetector) != nil
    end

    test "RejectionTracker is running" do
      assert Process.whereis(Arbor.Monitor.RejectionTracker) != nil
    end

    test "Verification is running" do
      assert Process.whereis(Arbor.Monitor.Verification) != nil
    end

    test "HealingWorkers DynamicSupervisor is running" do
      assert Process.whereis(Arbor.Monitor.HealingWorkers) != nil
    end
  end

  describe "worker management" do
    test "worker_count/0 returns count of workers" do
      count = HealingSupervisor.worker_count()
      assert count == 0
    end

    test "list_workers/0 returns empty list initially" do
      workers = HealingSupervisor.list_workers()
      assert workers == []
    end

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
  end
end
