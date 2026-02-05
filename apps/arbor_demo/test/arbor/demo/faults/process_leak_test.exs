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

      {:ok, pid} = ProcessLeak.inject(interval_ms: 10, batch_size: 10, supervisor: supervisor)
      assert Process.alive?(pid)

      Process.sleep(150)
      after_count = length(Process.list())
      assert after_count > initial_count + 20

      ProcessLeak.clear(pid)
    end
  end

  describe "clear/1" do
    test "stops controller and cleans up leaked processes", %{supervisor: supervisor} do
      {:ok, pid} = ProcessLeak.inject(interval_ms: 10, batch_size: 5, supervisor: supervisor)
      Process.sleep(100)

      leaked = GenServer.call(pid, :get_leaked)
      assert length(leaked) > 10

      :ok = ProcessLeak.clear(pid)
      Process.sleep(50)

      refute Process.alive?(pid)
      alive_leaked = Enum.count(leaked, &Process.alive?/1)
      assert alive_leaked == 0
    end

    test "handles nil reference" do
      assert :ok = ProcessLeak.clear(nil)
    end
  end
end
