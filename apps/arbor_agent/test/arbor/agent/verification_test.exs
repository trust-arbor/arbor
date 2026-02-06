defmodule Arbor.Agent.VerificationTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.Verification

  describe "verify_fix/4" do
    test "verifies killed process is dead" do
      # Spawn a process to kill
      pid = spawn(fn -> Process.sleep(10_000) end)
      assert Process.alive?(pid)

      # Kill it
      Process.exit(pid, :kill)

      anomaly = %{
        skill: :processes,
        details: %{pid: pid}
      }

      # Verify should pass
      result = Verification.verify_fix(anomaly, :kill_process, pid, delay_ms: 10, retries: 1)
      assert {:ok, :verified} = result
    end

    test "returns unverified when process still alive" do
      pid = spawn(fn -> Process.sleep(10_000) end)
      assert Process.alive?(pid)

      anomaly = %{
        skill: :processes,
        details: %{pid: pid}
      }

      # Don't actually kill it
      result = Verification.verify_fix(anomaly, :kill_process, pid, delay_ms: 10, retries: 1)
      assert {:ok, :unverified} = result

      # Cleanup
      Process.exit(pid, :kill)
    end

    test "verifies stopped supervisor is dead" do
      # Start a supervisor
      {:ok, sup} = Supervisor.start_link([], strategy: :one_for_one)
      assert Process.alive?(sup)

      # Stop it
      Supervisor.stop(sup)

      anomaly = %{
        skill: :supervisor,
        details: %{supervisor: sup}
      }

      result = Verification.verify_fix(anomaly, :stop_supervisor, sup, delay_ms: 10, retries: 1)
      assert {:ok, :verified} = result
    end

    test "verifies logged_warning action always succeeds" do
      anomaly = %{
        skill: :processes,
        details: %{}
      }

      result = Verification.verify_fix(anomaly, :logged_warning, nil, delay_ms: 0, retries: 0)
      assert {:ok, :verified} = result
    end

    test "verifies unknown action as success" do
      anomaly = %{
        skill: :processes,
        details: %{}
      }

      result = Verification.verify_fix(anomaly, :unknown_action, nil, delay_ms: 0, retries: 0)
      assert {:ok, :verified} = result
    end
  end

  describe "anomaly_still_present?/1" do
    test "returns false when process is dead" do
      pid = spawn(fn -> :ok end)
      Process.sleep(10)

      anomaly = %{
        skill: :processes,
        details: %{pid: pid}
      }

      refute Verification.anomaly_still_present?(anomaly)
    end

    test "returns true when process has large queue" do
      # Spawn a process and flood it
      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      for _ <- 1..2000, do: send(pid, :flood)

      anomaly = %{
        skill: :processes,
        details: %{pid: pid, threshold: 100}
      }

      assert Verification.anomaly_still_present?(anomaly)

      # Cleanup
      send(pid, :stop)
    end
  end

  describe "create_report/4" do
    test "creates verification report with metrics" do
      pid = spawn(fn -> Process.sleep(10_000) end)

      anomaly = %{
        skill: :processes,
        details: %{pid: pid}
      }

      # Kill the process
      Process.exit(pid, :kill)

      report = Verification.create_report(anomaly, :kill_process, pid, delay_ms: 10, retries: 1)

      assert report.anomaly_skill == :processes
      assert report.action == :kill_process
      assert is_binary(report.target)
      assert {:ok, :verified} = report.result
      assert is_map(report.before_metrics)
      assert is_map(report.after_metrics)
      assert %DateTime{} = report.verified_at
    end
  end

  describe "verify_condition/1 for :beam anomalies" do
    test "verifies when process count is reasonable" do
      anomaly = %{
        skill: :beam,
        details: %{process_count: :erlang.system_info(:process_count)}
      }

      # Current system should be healthy
      refute Verification.anomaly_still_present?(anomaly)
    end
  end

  describe "verify_condition/1 for :supervisor anomalies" do
    test "verifies when supervisor has active children" do
      # Start a supervisor with a child
      children = [
        %{
          id: :test_worker,
          start: {Task, :start_link, [fn -> Process.sleep(10_000) end]}
        }
      ]

      {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)

      anomaly = %{
        skill: :supervisor,
        details: %{supervisor: sup}
      }

      # Supervisor has active children, so anomaly is not present
      refute Verification.anomaly_still_present?(anomaly)

      Supervisor.stop(sup)
    end

    test "returns false when supervisor is dead" do
      {:ok, sup} = Supervisor.start_link([], strategy: :one_for_one)
      Supervisor.stop(sup)

      anomaly = %{
        skill: :supervisor,
        details: %{supervisor: sup}
      }

      refute Verification.anomaly_still_present?(anomaly)
    end
  end
end
