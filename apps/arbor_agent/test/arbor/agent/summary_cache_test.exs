defmodule Arbor.Agent.SummaryCacheTest do
  use ExUnit.Case, async: false

  alias Arbor.Agent.SummaryCache

  # This test needs the SummaryCache GenServer running
  setup do
    # Start cache if not already running
    case Process.whereis(SummaryCache) do
      nil ->
        {:ok, pid} = SummaryCache.start_link([])

        on_exit(fn ->
          if Process.alive?(pid), do: GenServer.stop(pid)
        end)

      _pid ->
        :ok
    end

    SummaryCache.clear()
    :ok
  end

  describe "hash_content/1" do
    test "produces consistent hash for same content" do
      messages = [%{role: "user", content: "hello"}]

      hash1 = SummaryCache.hash_content(messages)
      hash2 = SummaryCache.hash_content(messages)

      assert hash1 == hash2
    end

    test "produces different hashes for different content" do
      hash1 = SummaryCache.hash_content([%{role: "user", content: "hello"}])
      hash2 = SummaryCache.hash_content([%{role: "user", content: "world"}])

      assert hash1 != hash2
    end

    test "returns lowercase hex string" do
      hash = SummaryCache.hash_content([%{content: "test"}])

      assert is_binary(hash)
      assert String.match?(hash, ~r/^[0-9a-f]{64}$/)
    end
  end

  describe "put/2 and get/1" do
    test "stores and retrieves summary" do
      hash = SummaryCache.hash_content([%{content: "test"}])
      :ok = SummaryCache.put(hash, "This is a summary")

      assert {:ok, "This is a summary"} = SummaryCache.get(hash)
    end

    test "returns :not_found for missing key" do
      assert {:error, :not_found} = SummaryCache.get("nonexistent_hash")
    end

    test "overwrites existing entry" do
      hash = SummaryCache.hash_content([%{content: "test"}])

      :ok = SummaryCache.put(hash, "First summary")
      assert {:ok, "First summary"} = SummaryCache.get(hash)

      :ok = SummaryCache.put(hash, "Updated summary")
      assert {:ok, "Updated summary"} = SummaryCache.get(hash)
    end
  end

  describe "expiration" do
    test "returns :expired for entries past TTL" do
      # Set very short TTL
      Application.put_env(:arbor_agent, :summary_cache_ttl_minutes, 0)

      hash = SummaryCache.hash_content([%{content: "expiring"}])
      :ok = SummaryCache.put(hash, "Will expire")

      # With 0-minute TTL, should be expired immediately
      # (expires_at is in the past or exactly now)
      Process.sleep(10)
      assert {:error, :expired} = SummaryCache.get(hash)

      # Restore
      Application.put_env(:arbor_agent, :summary_cache_ttl_minutes, 60)
    end
  end

  describe "clear/0" do
    test "removes all entries" do
      hash1 = SummaryCache.hash_content([%{content: "a"}])
      hash2 = SummaryCache.hash_content([%{content: "b"}])

      :ok = SummaryCache.put(hash1, "Summary A")
      :ok = SummaryCache.put(hash2, "Summary B")

      assert SummaryCache.size() == 2

      :ok = SummaryCache.clear()

      assert SummaryCache.size() == 0
      assert {:error, :not_found} = SummaryCache.get(hash1)
    end
  end

  describe "size/0" do
    test "returns number of cached entries" do
      assert SummaryCache.size() == 0

      SummaryCache.put("hash1", "summary1")
      assert SummaryCache.size() == 1

      SummaryCache.put("hash2", "summary2")
      assert SummaryCache.size() == 2
    end
  end

  describe "cleanup" do
    test "GenServer handles :cleanup message" do
      # Insert an entry with 0 TTL (already expired)
      Application.put_env(:arbor_agent, :summary_cache_ttl_minutes, 0)
      SummaryCache.put("expired_hash", "old summary")
      Application.put_env(:arbor_agent, :summary_cache_ttl_minutes, 60)

      Process.sleep(10)

      # Trigger cleanup via message
      send(Process.whereis(SummaryCache), :cleanup)
      Process.sleep(50)

      assert {:error, :not_found} = SummaryCache.get("expired_hash")
    end
  end
end
