defmodule Arbor.Memory.IndexTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.Index

  @moduletag :fast

  setup do
    agent_id = "test_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = Index.start_link(agent_id: agent_id, name: nil)
    %{pid: pid, agent_id: agent_id}
  end

  describe "start_link/1" do
    test "starts with required agent_id" do
      agent_id = "start_test_#{System.unique_integer([:positive])}"
      {:ok, pid} = Index.start_link(agent_id: agent_id, name: nil)
      assert is_pid(pid)
      GenServer.stop(pid)
    end

    test "fails without agent_id" do
      assert_raise KeyError, fn ->
        Index.start_link([])
      end
    end
  end

  describe "index/3" do
    test "indexes content and returns entry id", %{pid: pid} do
      {:ok, entry_id} = Index.index(pid, "Hello, world!", %{type: :fact})

      assert is_binary(entry_id)
      assert String.starts_with?(entry_id, "mem_")
    end

    test "indexes content with metadata", %{pid: pid} do
      metadata = %{type: :fact, source: "test"}
      {:ok, entry_id} = Index.index(pid, "Test content", metadata)

      {:ok, entry} = Index.get(pid, entry_id)
      assert entry.metadata[:type] == :fact
      assert entry.metadata[:source] == "test"
    end

    test "can use pre-computed embedding", %{pid: pid} do
      embedding = List.duplicate(0.5, 128)
      {:ok, entry_id} = Index.index(pid, "Test", %{}, embedding: embedding)

      {:ok, entry} = Index.get(pid, entry_id)
      assert entry.embedding == embedding
    end
  end

  describe "recall/2" do
    test "returns similar content", %{pid: pid} do
      {:ok, _} = Index.index(pid, "The sky is blue", %{type: :fact})
      {:ok, _} = Index.index(pid, "Grass is green", %{type: :fact})
      {:ok, _} = Index.index(pid, "The ocean is blue", %{type: :fact})

      {:ok, results} = Index.recall(pid, "blue sky")

      assert is_list(results)
      assert results != []

      Enum.each(results, fn result ->
        assert Map.has_key?(result, :id)
        assert Map.has_key?(result, :content)
        assert Map.has_key?(result, :similarity)
      end)
    end

    test "filters by type", %{pid: pid} do
      {:ok, _} = Index.index(pid, "Fact one", %{type: :fact})
      {:ok, _} = Index.index(pid, "Experience one", %{type: :experience})
      {:ok, _} = Index.index(pid, "Fact two", %{type: :fact})

      {:ok, results} = Index.recall(pid, "one", type: :fact)

      Enum.each(results, fn result ->
        assert result.metadata[:type] == :fact
      end)
    end

    test "filters by multiple types", %{pid: pid} do
      {:ok, _} = Index.index(pid, "Fact one", %{type: :fact})
      {:ok, _} = Index.index(pid, "Skill one", %{type: :skill})
      {:ok, _} = Index.index(pid, "Insight one", %{type: :insight})

      {:ok, results} = Index.recall(pid, "one", types: [:fact, :skill])

      types = Enum.map(results, & &1.metadata[:type])
      assert Enum.all?(types, &(&1 in [:fact, :skill]))
    end

    test "respects limit", %{pid: pid} do
      for i <- 1..10 do
        {:ok, _} = Index.index(pid, "Content #{i}", %{type: :fact})
      end

      {:ok, results} = Index.recall(pid, "content", limit: 3)
      assert length(results) <= 3
    end

    test "respects threshold", %{pid: pid} do
      {:ok, _} = Index.index(pid, "Exact match content", %{type: :fact})
      {:ok, _} = Index.index(pid, "Something completely different", %{type: :fact})

      {:ok, results} = Index.recall(pid, "exact match", threshold: 0.9)

      Enum.each(results, fn result ->
        assert result.similarity >= 0.9
      end)
    end
  end

  describe "batch_index/2" do
    test "indexes multiple items", %{pid: pid} do
      items = [
        {"Fact one", %{type: :fact}},
        {"Fact two", %{type: :fact}},
        {"Skill one", %{type: :skill}}
      ]

      {:ok, ids} = Index.batch_index(pid, items)

      assert length(ids) == 3
      Enum.each(ids, &assert(String.starts_with?(&1, "mem_")))
    end
  end

  describe "stats/1" do
    test "returns index statistics", %{pid: pid, agent_id: agent_id} do
      {:ok, _} = Index.index(pid, "Content 1", %{})
      {:ok, _} = Index.index(pid, "Content 2", %{})

      stats = Index.stats(pid)

      assert stats.agent_id == agent_id
      assert stats.entry_count == 2
      assert is_integer(stats.max_entries)
      assert is_float(stats.default_threshold)
    end
  end

  describe "clear/1" do
    test "removes all entries", %{pid: pid} do
      {:ok, _} = Index.index(pid, "Content 1", %{})
      {:ok, _} = Index.index(pid, "Content 2", %{})

      assert Index.stats(pid).entry_count == 2

      :ok = Index.clear(pid)

      assert Index.stats(pid).entry_count == 0
    end
  end

  describe "get/2" do
    test "returns entry by id", %{pid: pid} do
      {:ok, entry_id} = Index.index(pid, "Test content", %{type: :fact})

      {:ok, entry} = Index.get(pid, entry_id)

      assert entry.id == entry_id
      assert entry.content == "Test content"
    end

    test "returns error for unknown id", %{pid: pid} do
      assert {:error, :not_found} = Index.get(pid, "unknown_id")
    end

    test "updates access time and count", %{pid: pid} do
      {:ok, entry_id} = Index.index(pid, "Test", %{})

      {:ok, entry1} = Index.get(pid, entry_id)
      assert entry1.access_count == 1

      {:ok, entry2} = Index.get(pid, entry_id)
      assert entry2.access_count == 2
    end
  end

  describe "delete/2" do
    test "removes entry by id", %{pid: pid} do
      {:ok, entry_id} = Index.index(pid, "Test content", %{})

      :ok = Index.delete(pid, entry_id)

      assert {:error, :not_found} = Index.get(pid, entry_id)
    end

    test "returns error for unknown id", %{pid: pid} do
      assert {:error, :not_found} = Index.delete(pid, "unknown_id")
    end
  end

  describe "LRU eviction" do
    test "evicts least recently accessed entries when at capacity" do
      agent_id = "eviction_test_#{System.unique_integer([:positive])}"
      # Small max to test eviction
      {:ok, pid} = Index.start_link(agent_id: agent_id, max_entries: 10, name: nil)

      # Add 15 entries (5 over capacity)
      for i <- 1..15 do
        {:ok, _} = Index.index(pid, "Content #{i}", %{})
      end

      stats = Index.stats(pid)
      # Should have evicted some
      assert stats.entry_count < 15

      GenServer.stop(pid)
    end
  end
end
