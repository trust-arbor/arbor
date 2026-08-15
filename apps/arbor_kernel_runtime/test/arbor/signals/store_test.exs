defmodule Arbor.Signals.StoreTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Signals.Signal
  alias Arbor.Signals.Store

  # Helper to restart the Store GenServer with custom opts under the app supervisor
  defp restart_store_with(opts) do
    supervisor = Arbor.Signals.Supervisor

    Supervisor.terminate_child(supervisor, Store)
    Supervisor.delete_child(supervisor, Store)
    Supervisor.start_child(supervisor, {Store, opts})
    # Give the new process time to initialize
    Process.sleep(20)
  end

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

  describe "eviction" do
    test "evicts oldest signal when max_signals exceeded" do
      # Restart store with a tiny max via the application supervisor
      restart_store_with(max_signals: 3)

      event_types = [:evict_event_1, :evict_event_2, :evict_event_3, :evict_event_4]

      signals =
        for {type, i} <- Enum.with_index(event_types, 1) do
          signal = Signal.new(:test, type, %{index: i})
          Store.put(signal)
          Process.sleep(10)
          signal
        end

      Process.sleep(50)

      # First signal should have been evicted
      assert {:error, :not_found} = Store.get(hd(signals).id)

      # Last 3 should still be present
      for signal <- Enum.drop(signals, 1) do
        assert {:ok, _} = Store.get(signal.id)
      end

      stats = Store.stats()
      assert stats.total_evicted >= 1
      assert stats.current_count == 3
    after
      restart_store_with([])
    end

    test "evicts multiple when many signals added rapidly" do
      restart_store_with(max_signals: 2)

      signals =
        for i <- 1..5 do
          signal = Signal.new(:test, :rapid_evict, %{index: i})
          Store.put(signal)
          Process.sleep(10)
          signal
        end

      Process.sleep(50)

      # Only last 2 should remain
      stats = Store.stats()
      assert stats.current_count == 2
      assert stats.total_evicted >= 3

      # First 3 should be gone
      for signal <- Enum.take(signals, 3) do
        assert {:error, :not_found} = Store.get(signal.id)
      end

      # Last 2 should exist
      for signal <- Enum.drop(signals, 3) do
        assert {:ok, _} = Store.get(signal.id)
      end
    after
      restart_store_with([])
    end
  end

  describe "cleanup_expired" do
    test "removes expired signals on cleanup timer" do
      restart_store_with(ttl_seconds: 1)

      signal = Signal.new(:test, :expiring_signal, %{})
      Store.put(signal)
      Process.sleep(50)

      # Signal should exist initially
      assert {:ok, _} = Store.get(signal.id)

      # Wait for expiry and trigger cleanup manually
      Process.sleep(1100)
      send(Process.whereis(Store), :cleanup)
      Process.sleep(100)

      # Signal should be cleaned up
      assert {:error, :not_found} = Store.get(signal.id)

      stats = Store.stats()
      assert stats.total_expired >= 1
    after
      restart_store_with([])
    end

    test "keeps non-expired signals during cleanup" do
      # Default TTL is 3600s, no need to restart; just trigger cleanup
      signal = Signal.new(:test, :not_expiring, %{})
      Store.put(signal)
      Process.sleep(50)

      # Trigger cleanup manually
      send(Process.whereis(Store), :cleanup)
      Process.sleep(100)

      # Signal should still be present (TTL is default 3600 seconds)
      assert {:ok, _} = Store.get(signal.id)
    end
  end

  describe "recent/1 with filters" do
    test "filters by category" do
      marker = System.unique_integer([:positive])
      Store.put(Signal.new(:alpha, :recent_cat, %{marker: marker}))
      Store.put(Signal.new(:beta, :recent_cat, %{marker: marker}))
      Process.sleep(50)

      {:ok, recent} = Store.recent(category: :alpha)
      alpha_with_marker = Enum.filter(recent, &(&1.data[:marker] == marker))
      assert alpha_with_marker != []
      assert Enum.all?(alpha_with_marker, fn s -> s.category == :alpha end)
    end

    test "filters by type" do
      marker = System.unique_integer([:positive])
      Store.put(Signal.new(:test, :recent_type_a, %{marker: marker}))
      Store.put(Signal.new(:test, :recent_type_b, %{marker: marker}))
      Process.sleep(50)

      {:ok, recent} = Store.recent(type: :recent_type_a)
      matched = Enum.filter(recent, &(&1.data[:marker] == marker))
      assert matched != []
      assert Enum.all?(matched, fn s -> s.type == :recent_type_a end)
    end

    test "returns signals in reverse chronological order with limit" do
      marker = System.unique_integer([:positive])

      for i <- 1..5 do
        Store.put(Signal.new(:test, :recent_order, %{index: i, marker: marker}))
        Process.sleep(10)
      end

      Process.sleep(50)

      {:ok, recent} = Store.recent(limit: 3, type: :recent_order)
      matched = Enum.filter(recent, &(&1.data[:marker] == marker))
      assert matched != []
      # Most recent should be first
      indices = Enum.map(matched, & &1.data.index)
      assert indices == Enum.sort(indices, :desc)
    end
  end

  describe "query/1 with source filter" do
    test "queries by source" do
      marker = System.unique_integer([:positive])
      Store.put(Signal.new(:test, :sourced_q, %{marker: marker}, source: "agent_1"))
      Store.put(Signal.new(:test, :sourced_q, %{marker: marker}, source: "agent_2"))
      Process.sleep(50)

      {:ok, results} = Store.query(source: "agent_1", type: :sourced_q)
      matched = Enum.filter(results, &(&1.data[:marker] == marker))
      assert matched != []
      assert Enum.all?(matched, fn s -> s.source == "agent_1" end)
    end
  end
end
