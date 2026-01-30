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
      assert {:error, :not_found} = Store.get("sig_definitely_not_here")
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
      # Use a unique marker in data rather than a dynamic atom type
      marker = System.unique_integer([:positive])
      signal = Signal.new(:activity, :store_filter_type, %{marker: marker})
      Store.put(signal)
      :timer.sleep(10)

      {:ok, results} = Store.query(type: :store_filter_type)
      assert Enum.any?(results, &(&1.data.marker == marker))
    end

    test "respects limit" do
      marker = System.unique_integer([:positive])

      for i <- 1..5 do
        Store.put(Signal.new(:activity, :store_limit_test, %{i: i, marker: marker}))
      end

      :timer.sleep(20)

      {:ok, results} = Store.query(type: :store_limit_test, limit: 2)
      assert length(results) == 2
    end

    test "returns results sorted by timestamp descending" do
      marker = System.unique_integer([:positive])

      for i <- 1..3 do
        Store.put(Signal.new(:activity, :store_order_test, %{i: i, marker: marker}))
        :timer.sleep(5)
      end

      :timer.sleep(10)

      {:ok, results} = Store.query(type: :store_order_test)

      timestamps = Enum.map(results, & &1.timestamp)
      assert timestamps == Enum.sort(timestamps, {:desc, DateTime})
    end
  end

  describe "recent/1" do
    test "returns recent signals" do
      Store.put(Signal.new(:activity, :store_recent_test, %{}))
      :timer.sleep(10)

      {:ok, results} = Store.recent(type: :store_recent_test, limit: 1)
      assert results != []
    end
  end

  describe "clear/0" do
    test "removes all signals" do
      signal = Signal.new(:activity, :store_clear_test, %{})
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
