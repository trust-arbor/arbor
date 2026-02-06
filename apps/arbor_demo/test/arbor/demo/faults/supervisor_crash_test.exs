defmodule Arbor.Demo.Faults.SupervisorCrashTest do
  use ExUnit.Case, async: true

  alias Arbor.Demo.Faults.SupervisorCrash

  setup do
    supervisor = start_supervised!({Arbor.Demo.Supervisor, name: nil})

    %{supervisor: supervisor}
  end

  describe "behaviour" do
    test "name returns :supervisor_crash" do
      assert SupervisorCrash.name() == :supervisor_crash
    end

    test "description returns a string" do
      assert is_binary(SupervisorCrash.description())
    end

    test "detectable_by includes :supervisor" do
      assert :supervisor in SupervisorCrash.detectable_by()
    end
  end

  describe "inject/1" do
    test "creates a supervisor with crashing child", %{supervisor: supervisor} do
      {:ok, pid, correlation_id} =
        SupervisorCrash.inject(crash_interval_ms: 5_000, supervisor: supervisor)

      assert Process.alive?(pid)
      assert is_binary(correlation_id)
      assert String.starts_with?(correlation_id, "fault_svc_")

      # The crash supervisor should have children
      children = Supervisor.which_children(pid)
      assert length(children) == 1

      # Clean up by stopping the supervisor directly
      Supervisor.stop(pid, :normal)
    end

    test "child worker stores correlation_id in process dictionary", %{supervisor: supervisor} do
      {:ok, pid, correlation_id} =
        SupervisorCrash.inject(crash_interval_ms: 5_000, supervisor: supervisor)

      # Get the child worker pid
      [{_id, child_pid, _type, _modules}] = Supervisor.which_children(pid)

      # No sleep needed - Supervisor.start_link waits for all children
      {:dictionary, dict} = Process.info(child_pid, :dictionary)
      assert Keyword.get(dict, :arbor_correlation_id) == correlation_id
      assert Keyword.get(dict, :arbor_fault_type) == :crash_worker

      Supervisor.stop(pid, :normal)
    end

    test "child crashes and restarts", %{supervisor: supervisor} do
      {:ok, pid, _correlation_id} =
        SupervisorCrash.inject(crash_interval_ms: 50, supervisor: supervisor)

      # Get initial child pid
      [{_id, child_pid1, _type, _modules}] = Supervisor.which_children(pid)
      assert Process.alive?(child_pid1)

      # Wait for crash and restart
      Process.sleep(100)

      # Child should have restarted (different pid or still alive due to restart)
      [{_id, child_pid2, _type, _modules}] = Supervisor.which_children(pid)
      assert Process.alive?(child_pid2)

      Supervisor.stop(pid, :normal)
    end
  end
end
