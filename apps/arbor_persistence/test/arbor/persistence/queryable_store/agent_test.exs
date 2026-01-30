defmodule Arbor.Persistence.QueryableStore.AgentTest do
  use ExUnit.Case, async: true

  alias Arbor.Persistence.{Filter, Record}
  alias Arbor.Persistence.QueryableStore.Agent, as: QSAgent

  setup do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    name = :"qs_agent_#{:erlang.unique_integer([:positive])}"
    start_supervised!({QSAgent, name: name})
    {:ok, name: name}
  end

  describe "CRUD operations" do
    test "put and get a record", %{name: name} do
      record = Record.new("user:1", %{name: "Alice"})
      assert :ok = QSAgent.put("user:1", record, name: name)
      assert {:ok, ^record} = QSAgent.get("user:1", name: name)
    end

    test "returns not_found for missing key", %{name: name} do
      assert {:error, :not_found} = QSAgent.get("missing", name: name)
    end

    test "delete removes record", %{name: name} do
      record = Record.new("key", %{})
      QSAgent.put("key", record, name: name)
      assert :ok = QSAgent.delete("key", name: name)
      assert {:error, :not_found} = QSAgent.get("key", name: name)
    end

    test "list returns all keys", %{name: name} do
      QSAgent.put("a", Record.new("a"), name: name)
      QSAgent.put("b", Record.new("b"), name: name)
      {:ok, keys} = QSAgent.list(name: name)
      assert Enum.sort(keys) == ["a", "b"]
    end

    test "exists? checks key presence", %{name: name} do
      QSAgent.put("key", Record.new("key"), name: name)
      assert QSAgent.exists?("key", name: name)
      refute QSAgent.exists?("nope", name: name)
    end
  end

  describe "query/2" do
    test "filters and orders records", %{name: name} do
      QSAgent.put("a", Record.new("a", %{type: "x"}), name: name)
      QSAgent.put("b", Record.new("b", %{type: "y"}), name: name)
      QSAgent.put("c", Record.new("c", %{type: "x"}), name: name)

      filter = Filter.new() |> Filter.where(:key, :in, ["a", "c"]) |> Filter.order_by(:key, :asc)
      {:ok, results} = QSAgent.query(filter, name: name)
      assert length(results) == 2
      assert Enum.map(results, & &1.key) == ["a", "c"]
    end
  end

  describe "count/2" do
    test "counts matching records", %{name: name} do
      QSAgent.put("a", Record.new("a"), name: name)
      QSAgent.put("b", Record.new("b"), name: name)

      {:ok, count} = QSAgent.count(Filter.new(), name: name)
      assert count == 2
    end
  end

  describe "child_spec/1" do
    test "returns valid child spec" do
      spec = QSAgent.child_spec(name: :test_qs)
      assert spec.id == :test_qs
      assert spec.type == :worker
      assert {QSAgent, :start_link, [_opts]} = spec.start
    end

    test "uses module as default id" do
      spec = QSAgent.child_spec([])
      assert spec.id == QSAgent
    end
  end

  describe "aggregate/4 operations" do
    setup %{name: name} do
      for {key, val} <- [{"a", 10}, {"b", 20}, {"c", 30}] do
        record = Record.new(key, %{}) |> Map.put(:score, val)
        QSAgent.put(key, record, name: name)
      end

      :ok
    end

    test "computes avg", %{name: name} do
      {:ok, result} = QSAgent.aggregate(Filter.new(), :score, :avg, name: name)
      assert result == 20.0
    end

    test "computes min", %{name: name} do
      {:ok, result} = QSAgent.aggregate(Filter.new(), :score, :min, name: name)
      assert result == 10
    end

    test "computes max", %{name: name} do
      {:ok, result} = QSAgent.aggregate(Filter.new(), :score, :max, name: name)
      assert result == 30
    end

    test "returns nil for empty results" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      empty_name = :"qs_empty_#{:erlang.unique_integer([:positive])}"
      start_supervised!({QSAgent, name: empty_name})

      {:ok, result} = QSAgent.aggregate(Filter.new(), :score, :sum, name: empty_name)
      assert result == nil
    end

    test "returns nil for non-numeric field", %{name: name} do
      # Records have :key as string, not number
      {:ok, result} = QSAgent.aggregate(Filter.new(), :nonexistent, :sum, name: name)
      assert result == nil
    end
  end

  describe "aggregate/4" do
    test "computes sum", %{name: name} do
      for {key, val} <- [{"a", 10}, {"b", 20}] do
        record = Record.new(key, %{}) |> Map.put(:score, val)
        QSAgent.put(key, record, name: name)
      end

      {:ok, result} = QSAgent.aggregate(Filter.new(), :score, :sum, name: name)
      assert result == 30
    end
  end
end
