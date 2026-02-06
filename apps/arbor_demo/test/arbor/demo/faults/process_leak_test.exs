defmodule Arbor.Demo.Faults.ProcessLeakTest do
  use ExUnit.Case, async: true

  alias Arbor.Demo.Faults.ProcessLeak

  setup do
    supervisor = start_supervised!({Arbor.Demo.Supervisor, name: nil})

    %{supervisor: supervisor}
  end

  describe "behaviour" do
    test "name returns :process_leak" do
      assert ProcessLeak.name() == :process_leak
    end

    test "description returns a string" do
      assert is_binary(ProcessLeak.description())
    end

    test "detectable_by includes :beam" do
      assert :beam in ProcessLeak.detectable_by()
    end
  end

  describe "inject/1" do
    test "spawns controller that creates leaked processes", %{supervisor: supervisor} do
      initial_count = length(Process.list())

      {:ok, pid, correlation_id} =
        ProcessLeak.inject(interval_ms: 10, batch_size: 10, supervisor: supervisor)

      assert Process.alive?(pid)
      assert is_binary(correlation_id)
      assert String.starts_with?(correlation_id, "fault_plk_")

      Process.sleep(150)
      after_count = length(Process.list())
      assert after_count > initial_count + 20

      # Clean up by stopping the GenServer
      GenServer.stop(pid, :normal)
    end

    test "stores correlation_id in process dictionary", %{supervisor: supervisor} do
      {:ok, pid, correlation_id} = ProcessLeak.inject(interval_ms: 50, supervisor: supervisor)

      # No sleep needed - GenServer init is synchronous
      {:dictionary, dict} = Process.info(pid, :dictionary)
      assert Keyword.get(dict, :arbor_correlation_id) == correlation_id
      assert Keyword.get(dict, :arbor_fault_type) == :process_leak

      GenServer.stop(pid, :normal)
    end

    test "controller tracks leaked processes", %{supervisor: supervisor} do
      {:ok, pid, _correlation_id} =
        ProcessLeak.inject(interval_ms: 10, batch_size: 5, supervisor: supervisor)

      Process.sleep(100)

      leaked = GenServer.call(pid, :get_leaked)
      assert length(leaked) > 10
      assert Enum.all?(leaked, &is_pid/1)

      GenServer.stop(pid, :normal)
    end
  end
end
