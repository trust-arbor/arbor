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
      {:ok, pid} =
        SupervisorCrash.inject(crash_interval_ms: 5_000, supervisor: supervisor)

      assert Process.alive?(pid)

      # The crash supervisor should have children
      children = Supervisor.which_children(pid)
      assert length(children) == 1

      SupervisorCrash.clear(pid)
    end
  end

  describe "clear/1" do
    test "stops the crash supervisor", %{supervisor: supervisor} do
      {:ok, pid} =
        SupervisorCrash.inject(crash_interval_ms: 5_000, supervisor: supervisor)

      assert Process.alive?(pid)
      :ok = SupervisorCrash.clear(pid)
      Process.sleep(50)
      refute Process.alive?(pid)
    end

    test "handles nil reference" do
      assert :ok = SupervisorCrash.clear(nil)
    end
  end
end
