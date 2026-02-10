defmodule Arbor.Memory.DurableStoreTest do
  @moduledoc """
  Tests for DurableStore embedding functions (embed_async/4 and semantic_search/3).
  """

  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Memory.DurableStore

  describe "embed_async/4" do
    test "returns :ok with nil agent_id (no-op)" do
      assert :ok = DurableStore.embed_async("goals", "key1", "some content", agent_id: nil)
    end

    test "returns :ok with empty content (no-op)" do
      assert :ok = DurableStore.embed_async("goals", "key1", "", agent_id: "agent_abc")
    end

    test "returns :ok with nil content (no-op)" do
      assert :ok = DurableStore.embed_async("goals", "key1", nil, agent_id: "agent_abc")
    end

    test "returns :ok with no opts (no agent_id)" do
      assert :ok = DurableStore.embed_async("goals", "key1", "some content")
    end

    test "returns :ok with valid inputs (fires async task)" do
      # With embedding_test_fallback: true, AI.embed uses TestEmbedding
      # The Task will fire but Embedding.store will fail without Postgres — that's OK,
      # embed_async catches all errors gracefully.
      assert :ok =
               DurableStore.embed_async("goals", "key1", "test goal content",
                 agent_id: "agent_test",
                 type: :goal
               )
    end
  end

  describe "semantic_search/3" do
    test "returns {:ok, []} with nil agent_id" do
      assert {:ok, []} = DurableStore.semantic_search("query", "goals", agent_id: nil)
    end

    test "returns {:ok, []} with empty query" do
      assert {:ok, []} = DurableStore.semantic_search("", "goals", agent_id: "agent_abc")
    end

    test "returns {:ok, []} with nil query" do
      assert {:ok, []} = DurableStore.semantic_search(nil, "goals", agent_id: "agent_abc")
    end

    test "returns {:ok, []} with no opts (no agent_id)" do
      assert {:ok, []} = DurableStore.semantic_search("query", "goals")
    end

    test "degrades gracefully when database unavailable" do
      # AI.embed succeeds (test fallback), but Embedding.search needs Postgres.
      # The catch clause in semantic_search returns {:ok, []} on any error.
      assert {:ok, []} =
               DurableStore.semantic_search("test query", "goals", agent_id: "agent_test")
    end
  end
end
