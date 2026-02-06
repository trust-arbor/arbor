defmodule Arbor.Actions.RemediationTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Remediation

  describe "KillProcess" do
    test "kills a live process" do
      pid = spawn(fn -> Process.sleep(10_000) end)
      pid_string = inspect(pid)

      assert Process.alive?(pid)
      {:ok, result} = Remediation.KillProcess.run(%{pid: pid_string}, %{})

      assert result.killed == true
      assert result.was_alive == true
      # Give process time to die
      Process.sleep(10)
      refute Process.alive?(pid)
    end

    test "handles already dead process" do
      pid = spawn(fn -> :ok end)
      Process.sleep(10)
      pid_string = inspect(pid)

      refute Process.alive?(pid)
      {:ok, result} = Remediation.KillProcess.run(%{pid: pid_string}, %{})

      assert result.killed == false
      assert result.was_alive == false
    end

    test "returns error for invalid pid format" do
      {:error, reason} = Remediation.KillProcess.run(%{pid: "invalid"}, %{})
      assert reason == :invalid_pid_format
    end

    test "accepts different exit reasons" do
      pid = spawn(fn -> Process.sleep(10_000) end)
      pid_string = inspect(pid)

      {:ok, result} =
        Remediation.KillProcess.run(%{pid: pid_string, reason: :kill}, %{})

      assert result.killed == true
    end
  end

  describe "StopSupervisor" do
    test "stops a supervisor" do
      # Use unlink to prevent EXIT propagation to test process
      {:ok, sup} = Supervisor.start_link([], strategy: :one_for_one)
      Process.unlink(sup)
      pid_string = inspect(sup)

      assert Process.alive?(sup)
      {:ok, result} = Remediation.StopSupervisor.run(%{pid: pid_string}, %{})

      assert result.stopped == true
      Process.sleep(10)
      refute Process.alive?(sup)
    end

    test "handles non-supervisor process" do
      pid = spawn(fn -> Process.sleep(10_000) end)
      pid_string = inspect(pid)

      {:ok, result} = Remediation.StopSupervisor.run(%{pid: pid_string, timeout: 100}, %{})
      # Will fail because it's not a supervisor - returns :timeout or :not_supervisor
      assert result.stopped == false
      assert result.result in [:not_supervisor, :timeout]

      Process.exit(pid, :kill)
    end

    test "returns error for invalid pid format" do
      {:error, reason} = Remediation.StopSupervisor.run(%{pid: "invalid"}, %{})
      assert reason == :invalid_pid_format
    end
  end

  describe "RestartChild" do
    test "restarts a supervisor child" do
      child_spec = %{
        id: :test_worker,
        start: {Task, :start_link, [fn -> Process.sleep(10_000) end]},
        restart: :transient
      }

      {:ok, sup} = Supervisor.start_link([child_spec], strategy: :one_for_one)
      sup_pid_string = inspect(sup)

      # Get the original child pid
      [{:test_worker, original_pid, _, _}] = Supervisor.which_children(sup)

      {:ok, result} =
        Remediation.RestartChild.run(
          %{supervisor_pid: sup_pid_string, child_id: :test_worker},
          %{}
        )

      assert result.restarted == true

      # Get the new child pid
      [{:test_worker, new_pid, _, _}] = Supervisor.which_children(sup)
      assert new_pid != original_pid

      Supervisor.stop(sup)
    end

    test "handles non-existent child" do
      {:ok, sup} = Supervisor.start_link([], strategy: :one_for_one)
      sup_pid_string = inspect(sup)

      {:ok, result} =
        Remediation.RestartChild.run(
          %{supervisor_pid: sup_pid_string, child_id: :nonexistent},
          %{}
        )

      assert result.restarted == false
      assert result.reason == :child_not_found

      Supervisor.stop(sup)
    end
  end

  describe "ForceGC" do
    test "forces garbage collection on a process" do
      pid =
        spawn(fn ->
          # Allocate some memory
          _list = Enum.to_list(1..10_000)

          receive do
            :stop -> :ok
          end
        end)

      Process.sleep(10)
      pid_string = inspect(pid)

      {:ok, result} = Remediation.ForceGC.run(%{pid: pid_string}, %{})

      assert result.collected == true
      assert is_integer(result.memory_after)

      send(pid, :stop)
    end

    test "handles dead process" do
      pid = spawn(fn -> :ok end)
      Process.sleep(10)
      pid_string = inspect(pid)

      {:ok, result} = Remediation.ForceGC.run(%{pid: pid_string}, %{})

      assert result.collected == false
      assert result.reason == :not_alive
    end
  end

  describe "DrainQueue" do
    test "inspects queue and suggests remediation" do
      # Create a process with a flooded queue
      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      # Flood the queue
      for _ <- 1..100, do: send(pid, :flood)
      pid_string = inspect(pid)

      {:ok, result} = Remediation.DrainQueue.run(%{pid: pid_string}, %{})

      assert result.inspected == true
      assert result.queue_len >= 100
      assert result.can_drain == false
      assert result.suggestion == :kill_process

      send(pid, :stop)
    end

    test "handles dead process" do
      pid = spawn(fn -> :ok end)
      Process.sleep(10)
      pid_string = inspect(pid)

      {:ok, result} = Remediation.DrainQueue.run(%{pid: pid_string}, %{})

      assert result.inspected == false
      assert result.reason == :not_alive
    end
  end
end
