defmodule Arbor.Memory.MemoryStoreTest do
  @moduledoc """
  Tests for MemoryStore embedding functions (embed_async/4 and semantic_search/3).
  """

  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Memory.MemoryStore

  describe "embed_async/4" do
    test "rejects effectful content with nil agent_id" do
      assert {:error, {:memory_store, :invalid_request, :invalid_agent_id}} =
               MemoryStore.embed_async("goals", "key1", "some content", agent_id: nil)
    end

    test "rejects effectful content with missing agent_id" do
      assert {:error, {:memory_store, :invalid_request, :invalid_agent_id}} =
               MemoryStore.embed_async("goals", "key1", "some content")
    end

    test "rejects effectful content with malformed agent_id" do
      assert {:error, {:memory_store, :invalid_request, :invalid_agent_id}} =
               MemoryStore.embed_async("goals", "key1", "some content", agent_id: "  padded  ")

      assert {:error, {:memory_store, :invalid_request, :invalid_agent_id}} =
               MemoryStore.embed_async("goals", "key1", "some content", agent_id: "")

      assert {:error, {:memory_store, :invalid_request, :invalid_agent_id}} =
               MemoryStore.embed_async("goals", "key1", "some content", agent_id: :not_a_string)
    end

    test "returns :ok with empty content (no-op)" do
      assert :ok = MemoryStore.embed_async("goals", "key1", "", agent_id: "agent_abc")
    end

    test "returns :ok with nil content (no-op)" do
      assert :ok = MemoryStore.embed_async("goals", "key1", nil, agent_id: "agent_abc")
    end

    test "returns :ok with empty content even without agent_id (non-effectful)" do
      assert :ok = MemoryStore.embed_async("goals", "key1", "")
    end

    test "returns :ok with valid inputs (admits async writer)" do
      # With embedding_test_fallback: true, AI.embed uses TestEmbedding.
      # Admission may reject if bootstrap is not ready; that is a bounded error.
      result =
        MemoryStore.embed_async("goals", "key1", "test goal content",
          agent_id: "agent_test",
          type: :goal
        )

      assert result == :ok or
               match?({:error, {:memory_store, :async_writer, _}}, result)
    end
  end

  describe "semantic_search/3" do
    test "returns {:ok, []} with nil agent_id" do
      assert {:ok, []} = MemoryStore.semantic_search("query", "goals", agent_id: nil)
    end

    test "returns {:ok, []} with empty query" do
      assert {:ok, []} = MemoryStore.semantic_search("", "goals", agent_id: "agent_abc")
    end

    test "returns {:ok, []} with nil query" do
      assert {:ok, []} = MemoryStore.semantic_search(nil, "goals", agent_id: "agent_abc")
    end

    test "returns {:ok, []} with no opts (no agent_id)" do
      assert {:ok, []} = MemoryStore.semantic_search("query", "goals")
    end

    test "degrades gracefully when database unavailable" do
      # AI.embed succeeds (test fallback), but Embedding.search needs Postgres.
      # Unsupported / unavailable backends remain soft-empty; integrity failures hard-error.
      assert {:ok, []} =
               MemoryStore.semantic_search("test query", "goals", agent_id: "agent_test")
    end

    test "rejects a malformed option list before keyword access" do
      assert {:error, {:memory_store, :invalid_request, :invalid_options}} =
               MemoryStore.semantic_search("query", "goals", [:not_a_keyword])
    end
  end

  describe "delete_embedding/3" do
    test "rejects a malformed option list before keyword access" do
      assert {:error, {:memory_store, :invalid_request, :invalid_options}} =
               MemoryStore.delete_embedding("goals", "goal_1", [:not_a_keyword])
    end
  end
end
