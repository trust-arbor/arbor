defmodule Arbor.Monitor.Skills.EtsTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Monitor.Skills.Ets

  describe "name/0" do
    test "returns :ets" do
      assert Ets.name() == :ets
    end
  end

  describe "collect/0" do
    test "returns expected keys with valid types" do
      assert {:ok, metrics} = Ets.collect()

      assert is_integer(metrics.table_count)
      assert is_integer(metrics.total_memory_words)
      assert is_integer(metrics.total_memory_bytes)
      assert is_list(metrics.top_tables)

      assert metrics.table_count > 0
      assert metrics.total_memory_bytes > 0
    end

    test "top_tables entries have required fields" do
      assert {:ok, metrics} = Ets.collect()

      Enum.each(metrics.top_tables, fn table ->
        assert Map.has_key?(table, :name)
        assert Map.has_key?(table, :size)
        assert Map.has_key?(table, :memory_words)
        assert Map.has_key?(table, :type)
        assert is_integer(table.size)
        assert is_integer(table.memory_words)
      end)
    end

    test "top_tables are sorted by memory descending" do
      assert {:ok, metrics} = Ets.collect()

      memory_values = Enum.map(metrics.top_tables, & &1.memory_words)
      assert memory_values == Enum.sort(memory_values, :desc)
    end
  end

  describe "check/1" do
    test "returns :normal for healthy table count" do
      metrics = %{table_count: 50}
      assert :normal = Ets.check(metrics)
    end

    test "detects high table count" do
      metrics = %{table_count: 600}
      assert {:anomaly, :warning, details} = Ets.check(metrics)
      assert details.metric == :ets_table_count
      assert details.value == 600
    end
  end
end
