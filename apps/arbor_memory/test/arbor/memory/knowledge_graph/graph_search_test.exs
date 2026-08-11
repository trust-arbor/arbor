defmodule Arbor.Memory.KnowledgeGraph.GraphSearchTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.KnowledgeGraph
  alias Arbor.Memory.KnowledgeGraph.GraphSearch

  @moduletag :fast

  describe "semantic_search/3 similarity exposure" do
    test "attaches the already-computed blended score to each result additively" do
      graph = KnowledgeGraph.new("agent_001", auto_embed: false)

      {:ok, graph, id} =
        KnowledgeGraph.add_node(graph, %{
          type: :fact,
          content: "elixir pattern matching is great",
          skip_dedup: true
        })

      {:ok, results} = GraphSearch.semantic_search(graph, "pattern matching")

      assert [%{id: ^id, similarity: score} = result] = results
      assert is_float(score) and score > 0.0
      # Additive: every pre-existing field survives untouched alongside the
      # new key.
      assert result.content == "elixir pattern matching is great"
      assert result.type == :fact
    end

    test "the public KnowledgeGraph.semantic_search/3 delegate inherits the fix" do
      graph = KnowledgeGraph.new("agent_001", auto_embed: false)

      {:ok, graph, id} =
        KnowledgeGraph.add_node(graph, %{
          type: :fact,
          content: "deterministic keyword scoring",
          skip_dedup: true
        })

      {:ok, [%{id: ^id, similarity: score}]} =
        KnowledgeGraph.semantic_search(graph, "keyword scoring")

      assert is_float(score) and score > 0.0
    end

    test "does not depend on an external embedding service (auto_embed: false, no query embedding)" do
      graph = KnowledgeGraph.new("agent_001", auto_embed: false)

      {:ok, graph, _id} =
        KnowledgeGraph.add_node(graph, %{
          type: :fact,
          content: "no embeddings needed here",
          skip_dedup: true
        })

      # With no embeddings on either side, compute_search_score falls through
      # to pure deterministic keyword scoring -- this must succeed hermetically.
      assert {:ok, [%{similarity: score}]} =
               GraphSearch.semantic_search(graph, "embeddings needed")

      assert score == 1.0
    end
  end
end
