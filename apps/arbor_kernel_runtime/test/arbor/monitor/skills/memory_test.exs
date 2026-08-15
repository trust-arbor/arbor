defmodule Arbor.Monitor.Skills.MemoryTest do
  use ExUnit.Case, async: true

  alias Arbor.Monitor.Skills.Memory

  describe "collect/0" do
    test "returns memory breakdown" do
      assert {:ok, metrics} = Memory.collect()

      assert is_integer(metrics.total)
      assert is_integer(metrics.processes)
      assert is_integer(metrics.binary)
      assert is_integer(metrics.ets)
      assert is_integer(metrics.atom)
      assert is_integer(metrics.code)
      assert is_integer(metrics.system)

      assert metrics.total > 0
    end
  end

  describe "check/1" do
    test "returns :normal for healthy memory" do
      metrics = %{total: 100_000_000}
      assert :normal = Memory.check(metrics)
    end
  end

  describe "name/0" do
    test "returns :memory" do
      assert Memory.name() == :memory
    end
  end
end
