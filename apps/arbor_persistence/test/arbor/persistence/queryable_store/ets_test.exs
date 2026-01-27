defmodule Arbor.Persistence.QueryableStore.ETSTest do
  use ExUnit.Case, async: true

  alias Arbor.Persistence.QueryableStore.ETS
  alias Arbor.Persistence.{Record, Filter}

  setup do
    name = :"qs_ets_#{:erlang.unique_integer([:positive])}"
    start_supervised!({ETS, name: name})
    {:ok, name: name}
  end

  describe "CRUD operations" do
    test "put and get a record", %{name: name} do
      record = Record.new("user:1", %{name: "Alice"})
      assert :ok = ETS.put("user:1", record, name: name)
      assert {:ok, ^record} = ETS.get("user:1", name: name)
    end

    test "returns not_found for missing key", %{name: name} do
      assert {:error, :not_found} = ETS.get("missing", name: name)
    end

    test "delete removes record", %{name: name} do
      record = Record.new("key", %{})
      ETS.put("key", record, name: name)
      assert :ok = ETS.delete("key", name: name)
      assert {:error, :not_found} = ETS.get("key", name: name)
    end

    test "list returns all keys", %{name: name} do
      ETS.put("a", Record.new("a"), name: name)
      ETS.put("b", Record.new("b"), name: name)
      {:ok, keys} = ETS.list(name: name)
      assert Enum.sort(keys) == ["a", "b"]
    end

    test "exists? checks key presence", %{name: name} do
      ETS.put("key", Record.new("key"), name: name)
      assert ETS.exists?("key", name: name)
      refute ETS.exists?("nope", name: name)
    end
  end

  describe "query/2" do
    setup %{name: name} do
      records = [
        Record.new("u1", %{role: "admin", age: 30}),
        Record.new("u2", %{role: "user", age: 25}),
        Record.new("u3", %{role: "admin", age: 40})
      ]

      for {r, i} <- Enum.with_index(records) do
        ETS.put("key_#{i}", r, name: name)
      end

      {:ok, records: records}
    end

    test "filters by condition", %{name: name} do
      filter = Filter.new() |> Filter.where(:key, :eq, "u1")
      {:ok, results} = ETS.query(filter, name: name)
      assert length(results) == 1
      assert hd(results).key == "u1"
    end

    test "returns all with empty filter", %{name: name} do
      {:ok, results} = ETS.query(Filter.new(), name: name)
      assert length(results) == 3
    end

    test "applies ordering", %{name: name} do
      filter = Filter.new() |> Filter.order_by(:key, :desc)
      {:ok, results} = ETS.query(filter, name: name)
      keys = Enum.map(results, & &1.key)
      assert keys == ["u3", "u2", "u1"]
    end

    test "applies limit", %{name: name} do
      filter = Filter.new() |> Filter.order_by(:key, :asc) |> Filter.limit(2)
      {:ok, results} = ETS.query(filter, name: name)
      assert length(results) == 2
    end
  end

  describe "count/2" do
    test "counts matching records", %{name: name} do
      ETS.put("a", Record.new("a", %{type: "x"}), name: name)
      ETS.put("b", Record.new("b", %{type: "y"}), name: name)
      ETS.put("c", Record.new("c", %{type: "x"}), name: name)

      filter = Filter.new() |> Filter.where(:key, :in, ["a", "c"])
      {:ok, count} = ETS.count(filter, name: name)
      assert count == 2
    end
  end

  describe "aggregate/4" do
    setup %{name: name} do
      for {key, val} <- [{"a", 10}, {"b", 20}, {"c", 30}] do
        record = Record.new(key, %{}) |> Map.put(:score, val)
        ETS.put(key, record, name: name)
      end

      :ok
    end

    test "sum", %{name: name} do
      {:ok, result} = ETS.aggregate(Filter.new(), :score, :sum, name: name)
      assert result == 60
    end

    test "avg", %{name: name} do
      {:ok, result} = ETS.aggregate(Filter.new(), :score, :avg, name: name)
      assert_in_delta result, 20.0, 0.01
    end

    test "min", %{name: name} do
      {:ok, result} = ETS.aggregate(Filter.new(), :score, :min, name: name)
      assert result == 10
    end

    test "max", %{name: name} do
      {:ok, result} = ETS.aggregate(Filter.new(), :score, :max, name: name)
      assert result == 30
    end

    test "returns nil for no matching records", %{name: name} do
      filter = Filter.new() |> Filter.where(:key, :eq, "nonexistent")
      {:ok, result} = ETS.aggregate(filter, :score, :sum, name: name)
      assert result == nil
    end
  end
end
