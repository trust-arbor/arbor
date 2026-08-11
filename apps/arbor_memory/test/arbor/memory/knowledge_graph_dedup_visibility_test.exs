defmodule Arbor.Memory.KnowledgeGraphDedupVisibilityTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.KnowledgeGraph

  @moduletag :fast

  describe "add_node_with_outcome/2" do
    test "reports :created for a fresh insert and :deduplicated with the same id on retry" do
      graph = KnowledgeGraph.new("agent_001", auto_embed: false)

      {:ok, graph, id1, :created} =
        KnowledgeGraph.add_node_with_outcome(graph, %{type: :fact, content: "The sky is blue"})

      {:ok, graph, id2, :deduplicated} =
        KnowledgeGraph.add_node_with_outcome(graph, %{type: :fact, content: "The sky is blue"})

      assert id1 == id2
      assert map_size(graph.nodes) == 1
    end

    test "reports :created for skip_dedup even when content matches" do
      graph = KnowledgeGraph.new("agent_001", auto_embed: false)

      {:ok, graph, id1, :created} =
        KnowledgeGraph.add_node_with_outcome(graph, %{type: :fact, content: "Duplicate"})

      {:ok, graph, id2, :created} =
        KnowledgeGraph.add_node_with_outcome(graph, %{
          type: :fact,
          content: "Duplicate",
          skip_dedup: true
        })

      assert id1 != id2
      assert map_size(graph.nodes) == 2
    end

    test "add_node/2 keeps its unchanged three-tuple contract for the same inputs" do
      graph = KnowledgeGraph.new("agent_001", auto_embed: false)

      {:ok, graph, id1} =
        KnowledgeGraph.add_node(graph, %{type: :fact, content: "Stable contract"})

      {:ok, _graph, id2} =
        KnowledgeGraph.add_node(graph, %{type: :fact, content: "Stable contract"})

      assert id1 == id2
    end
  end

  describe "add_node_transition_with_outcome/4" do
    test "reports :created then :deduplicated with a stable id via the transition path" do
      graph = KnowledgeGraph.new("agent_001", auto_embed: false)
      occurred_at = ~U[2026-01-01 00:00:00Z]

      {:ok, graph, "node_fact_a", :created} =
        KnowledgeGraph.add_node_transition_with_outcome(
          graph,
          %{type: :fact, content: "Transition dedup fact"},
          "node_fact_a",
          occurred_at
        )

      {:ok, graph, "node_fact_a", :deduplicated} =
        KnowledgeGraph.add_node_transition_with_outcome(
          graph,
          %{type: :fact, content: "Transition dedup fact"},
          "node_fact_b",
          occurred_at
        )

      assert map_size(graph.nodes) == 1
    end

    test "add_node_transition/4 keeps its unchanged three-tuple contract" do
      graph = KnowledgeGraph.new("agent_001", auto_embed: false)
      occurred_at = ~U[2026-01-01 00:00:00Z]

      {:ok, graph, "node_fact_a"} =
        KnowledgeGraph.add_node_transition(
          graph,
          %{type: :fact, content: "Stable transition contract"},
          "node_fact_a",
          occurred_at
        )

      {:ok, _graph, "node_fact_a"} =
        KnowledgeGraph.add_node_transition(
          graph,
          %{type: :fact, content: "Stable transition contract"},
          "node_fact_b",
          occurred_at
        )
    end
  end
end
