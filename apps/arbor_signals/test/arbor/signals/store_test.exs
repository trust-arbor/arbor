defmodule Arbor.Signals.StoreTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Signals.Signal
  alias Arbor.Signals.Store

  describe "put/1 and get/1" do
    test "stores and retrieves a signal" do
      signal = Signal.new(:activity, :store_test_put, %{val: 1})
      Store.put(signal)
      # Give GenServer time to process the cast
      :timer.sleep(10)

      assert {:ok, retrieved} = Store.get(signal.id)
      assert retrieved.id == signal.id
      assert retrieved.data.val == 1
    end

    test "returns error for nonexistent signal" do
      assert {:error, :not_found} = Store.get("sig_nonexistent_#{System.unique_integer([:positive])}")
    end
  end

  describe "query/1" do
    test "filters by category" do
      signal = Signal.new(:metrics, :store_query_cat, %{})
      Store.put(signal)
      :timer.sleep(10)

      {:ok, results} = Store.query(category: :metrics, type: :store_query_cat)
      assert Enum.any?(results, &(&1.id == signal.id))
    end

    test "filters by type" do
      unique = :"store_type_#{System.unique_integer([:positive])}"
      signal = Signal.new(:activity, unique, %{})
      Store.put(signal)
      :timer.sleep(10)

      {:ok, results} = Store.query(type: unique)
      assert length(results) >= 1
      assert Enum.all?(results, &(&1.type == unique))
    end

    test "respects limit" do
      unique_type = :"store_limit_#{System.unique_integer([:positive])}"

      for i <- 1..5 do
        Store.put(Signal.new(:activity, unique_type, %{i: i}))
      end

      :timer.sleep(20)

      {:ok, results} = Store.query(type: unique_type, limit: 2)
      assert length(results) == 2
    end

    test "returns results sorted by timestamp descending" do
      unique_type = :"store_order_#{System.unique_integer([:positive])}"

      for i <- 1..3 do
        Store.put(Signal.new(:activity, unique_type, %{i: i}))
        :timer.sleep(5)
      end

      :timer.sleep(10)

      {:ok, results} = Store.query(type: unique_type)

      timestamps = Enum.map(results, & &1.timestamp)
      assert timestamps == Enum.sort(timestamps, {:desc, DateTime})
    end
  end

  describe "recent/1" do
    test "returns recent signals" do
      unique_type = :"store_recent_#{System.unique_integer([:positive])}"
      Store.put(Signal.new(:activity, unique_type, %{}))
      :timer.sleep(10)

      {:ok, results} = Store.recent(type: unique_type, limit: 1)
      assert length(results) >= 1
    end
  end

  describe "clear/0" do
    test "removes all signals" do
      unique_type = :"store_clear_#{System.unique_integer([:positive])}"
      signal = Signal.new(:activity, unique_type, %{})
      Store.put(signal)
      :timer.sleep(10)

      assert {:ok, _} = Store.get(signal.id)

      Store.clear()

      assert {:error, :not_found} = Store.get(signal.id)
    end
  end

  describe "stats/0" do
    test "returns store statistics" do
      stats = Store.stats()

      assert is_integer(stats.current_count)
      assert is_integer(stats.max_signals)
      assert is_integer(stats.ttl_seconds)
      assert is_integer(stats.total_stored)
      assert is_integer(stats.total_expired)
      assert is_integer(stats.total_evicted)
    end
  end
end
