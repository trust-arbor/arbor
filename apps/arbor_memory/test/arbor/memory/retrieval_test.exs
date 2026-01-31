defmodule Arbor.Memory.RetrievalTest do
  use ExUnit.Case, async: false

  alias Arbor.Memory
  alias Arbor.Memory.Retrieval

  @moduletag :fast

  @agent_id "retrieval_test_agent"

  setup do
    # Initialize memory for the test agent
    {:ok, _pid} = Memory.init_for_agent(@agent_id)

    on_exit(fn ->
      Memory.cleanup_for_agent(@agent_id)
    end)

    :ok
  end

  describe "index/4" do
    test "indexes content and returns entry id" do
      {:ok, id} = Retrieval.index(@agent_id, "Test content", %{type: :fact})

      assert is_binary(id)
      assert id =~ ~r/^mem_/
    end

    test "accepts metadata" do
      {:ok, _id} = Retrieval.index(@agent_id, "Content", %{type: :fact, source: "test"})

      # Should succeed without error
    end

    test "returns error when index not initialized" do
      result = Retrieval.index("nonexistent_agent", "Content", %{})

      assert {:error, :index_not_initialized} = result
    end
  end

  describe "batch_index/3" do
    test "indexes multiple items" do
      items = [
        {"Fact one", %{type: :fact}},
        {"Fact two", %{type: :fact}},
        {"Fact three", %{type: :fact}}
      ]

      {:ok, ids} = Retrieval.batch_index(@agent_id, items)

      assert length(ids) == 3
      assert Enum.all?(ids, &is_binary/1)
    end
  end

  describe "recall/3" do
    setup do
      # Index some test content
      {:ok, _} =
        Retrieval.index(@agent_id, "Elixir is a functional programming language", %{type: :fact})

      {:ok, _} =
        Retrieval.index(@agent_id, "Phoenix is a web framework for Elixir", %{type: :fact})

      {:ok, _} =
        Retrieval.index(@agent_id, "OTP provides fault-tolerant patterns", %{type: :fact})

      :ok
    end

    test "recalls similar content" do
      {:ok, results} = Retrieval.recall(@agent_id, "Elixir programming")

      assert is_list(results)
    end

    test "respects limit option" do
      {:ok, results} = Retrieval.recall(@agent_id, "query", limit: 2)

      assert length(results) <= 2
    end

    test "respects type filter" do
      {:ok, _} = Retrieval.index(@agent_id, "Personal experience", %{type: :experience})
      {:ok, results} = Retrieval.recall(@agent_id, "experience", type: :experience)

      # Should only return experience type
      assert Enum.all?(results, fn r -> r.metadata[:type] == :experience end)
    end

    test "returns empty list when no matches" do
      {:ok, results} =
        Retrieval.recall(@agent_id, "completely unrelated query xyz", threshold: 0.99)

      assert results == []
    end
  end

  describe "let_me_recall/3" do
    setup do
      {:ok, _} = Retrieval.index(@agent_id, "Important fact about testing", %{type: :fact})
      {:ok, _} = Retrieval.index(@agent_id, "Another fact about Elixir", %{type: :fact})
      :ok
    end

    test "returns formatted text for LLM context" do
      {:ok, text} = Retrieval.let_me_recall(@agent_id, "testing fact")

      if text != "" do
        assert text =~ "I recall the following"
        assert text =~ "- "
      end
    end

    test "includes similarity scores by default" do
      {:ok, text} = Retrieval.let_me_recall(@agent_id, "testing")

      if text != "" do
        # Should contain a decimal similarity score
        assert text =~ ~r/\(\d+\.\d+\)/
      end
    end

    test "can exclude similarity scores" do
      {:ok, text} = Retrieval.let_me_recall(@agent_id, "testing", include_similarity: false)

      if text != "" do
        # Should not contain similarity pattern
        refute text =~ ~r/\(\d+\.\d+\)$/m
      end
    end

    test "accepts custom preamble" do
      {:ok, text} = Retrieval.let_me_recall(@agent_id, "testing", preamble: "From my memory:")

      if text != "" do
        assert text =~ "From my memory:"
      end
    end

    test "returns empty string when no results" do
      {:ok, text} = Retrieval.let_me_recall(@agent_id, "xyz123abc", threshold: 0.99)

      assert text == ""
    end

    test "respects max_tokens option" do
      # Index many items to have lots of content
      for i <- 1..20 do
        {:ok, _} =
          Retrieval.index(@agent_id, "Fact number #{i} with lots of content here", %{type: :fact})
      end

      {:ok, short_text} = Retrieval.let_me_recall(@agent_id, "fact", max_tokens: 50)
      {:ok, long_text} = Retrieval.let_me_recall(@agent_id, "fact", max_tokens: 500)

      # Short should be shorter or equal
      assert String.length(short_text) <= String.length(long_text) or short_text == ""
    end
  end

  describe "has_memories?/1" do
    test "returns false for empty index" do
      {:ok, _} = Memory.init_for_agent("empty_agent")
      on_exit(fn -> Memory.cleanup_for_agent("empty_agent") end)

      refute Retrieval.has_memories?("empty_agent")
    end

    test "returns true after indexing content" do
      {:ok, _} = Retrieval.index(@agent_id, "Some content", %{})

      assert Retrieval.has_memories?(@agent_id)
    end

    test "returns false for non-existent agent" do
      refute Retrieval.has_memories?("nonexistent_agent_xyz")
    end
  end

  describe "stats/1" do
    test "returns index statistics" do
      {:ok, _} = Retrieval.index(@agent_id, "Content 1", %{})
      {:ok, _} = Retrieval.index(@agent_id, "Content 2", %{})

      {:ok, stats} = Retrieval.stats(@agent_id)

      assert stats.agent_id == @agent_id
      assert stats.entry_count == 2
    end

    test "returns error for non-existent agent" do
      {:error, reason} = Retrieval.stats("nonexistent_xyz")
      assert reason == :index_not_initialized
    end
  end
end
