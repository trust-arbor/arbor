defmodule Arbor.Orchestrator.DotCacheTest do
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.DotCache

  @simple_dot """
  digraph test {
    start -> end_node;
  }
  """

  @another_dot """
  digraph other {
    a -> b -> c;
  }
  """

  setup do
    # Ensure DotCache is running (may already be started by Application)
    case GenServer.whereis(DotCache) do
      nil -> start_supervised!(DotCache)
      _pid -> :ok
    end

    DotCache.clear()
    :ok
  end

  describe "cache_key/1" do
    test "produces a hex-encoded SHA-256 hash" do
      key = DotCache.cache_key("hello")
      assert is_binary(key)
      assert String.length(key) == 64
      assert key =~ ~r/^[0-9a-f]+$/
    end

    test "same input produces same key" do
      assert DotCache.cache_key("hello") == DotCache.cache_key("hello")
    end

    test "different input produces different key" do
      refute DotCache.cache_key("hello") == DotCache.cache_key("world")
    end
  end

  describe "get/1 and put/2" do
    test "returns :miss for uncached key" do
      assert :miss = DotCache.get("nonexistent")
    end

    test "caches and retrieves a graph" do
      key = DotCache.cache_key(@simple_dot)
      {:ok, graph} = Arbor.Orchestrator.parse(@simple_dot)

      assert :ok = DotCache.put(key, graph)
      assert {:ok, ^graph} = DotCache.get(key)
    end

    test "different sources get different cache entries" do
      key1 = DotCache.cache_key(@simple_dot)
      key2 = DotCache.cache_key(@another_dot)

      {:ok, graph1} = Arbor.Orchestrator.parse(@simple_dot)
      {:ok, graph2} = Arbor.Orchestrator.parse(@another_dot)

      DotCache.put(key1, graph1)
      DotCache.put(key2, graph2)

      assert {:ok, ^graph1} = DotCache.get(key1)
      assert {:ok, ^graph2} = DotCache.get(key2)
    end
  end

  describe "invalidate/1" do
    test "removes a cached entry" do
      key = DotCache.cache_key(@simple_dot)
      {:ok, graph} = Arbor.Orchestrator.parse(@simple_dot)

      DotCache.put(key, graph)
      assert {:ok, _} = DotCache.get(key)

      assert :ok = DotCache.invalidate(key)
      assert :miss = DotCache.get(key)
    end

    test "is idempotent for missing keys" do
      assert :ok = DotCache.invalidate("nonexistent")
    end
  end

  describe "clear/0" do
    test "removes all entries" do
      key1 = DotCache.cache_key(@simple_dot)
      key2 = DotCache.cache_key(@another_dot)
      {:ok, graph1} = Arbor.Orchestrator.parse(@simple_dot)
      {:ok, graph2} = Arbor.Orchestrator.parse(@another_dot)

      DotCache.put(key1, graph1)
      DotCache.put(key2, graph2)
      assert %{size: 2} = DotCache.stats()

      assert :ok = DotCache.clear()
      assert %{size: 0} = DotCache.stats()
    end
  end

  describe "stats/0" do
    test "returns size and max" do
      stats = DotCache.stats()
      assert is_integer(stats.size)
      assert is_integer(stats.max)
      assert stats.max > 0
    end

    test "size increases with puts" do
      assert %{size: 0} = DotCache.stats()

      key = DotCache.cache_key(@simple_dot)
      {:ok, graph} = Arbor.Orchestrator.parse(@simple_dot)
      DotCache.put(key, graph)

      assert %{size: 1} = DotCache.stats()
    end
  end

  describe "eviction" do
    test "evicts oldest entry when over max" do
      # Start a cache with max_entries=2 for testing
      # We use the global cache but it defaults to 100, so we test with many entries
      # Instead, test the eviction logic by inserting max+1 entries

      # Get current max
      %{max: max} = DotCache.stats()

      # Insert max+1 entries
      graphs =
        for i <- 0..max do
          source = "digraph g#{i} { n#{i} -> n#{i + 1}; }"
          key = DotCache.cache_key(source)
          {:ok, graph} = Arbor.Orchestrator.parse(source)
          DotCache.put(key, graph)
          {key, graph}
        end

      # Should have evicted one, so size should be max
      assert %{size: ^max} = DotCache.stats()

      # The last entry should still be present
      {last_key, last_graph} = List.last(graphs)
      assert {:ok, ^last_graph} = DotCache.get(last_key)
    end
  end

  describe "integration with Orchestrator" do
    test "second parse of same source hits cache" do
      key = DotCache.cache_key(@simple_dot)

      # First call — cache miss, should parse and cache
      Arbor.Orchestrator.validate(@simple_dot)

      # Should now be in cache
      assert {:ok, cached} = DotCache.get(key)
      assert %Arbor.Orchestrator.Graph{} = cached

      # Second call should use cached version (no way to directly assert cache hit
      # but we verify the entry persists)
      Arbor.Orchestrator.validate(@simple_dot)
      assert {:ok, _} = DotCache.get(key)
    end

    test "cache: false option bypasses cache" do
      key = DotCache.cache_key(@simple_dot)

      # Run with cache disabled
      Arbor.Orchestrator.validate(@simple_dot, cache: false)

      # Should NOT be in cache
      assert :miss = DotCache.get(key)
    end
  end
end
