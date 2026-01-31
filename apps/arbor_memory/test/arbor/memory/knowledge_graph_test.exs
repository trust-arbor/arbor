defmodule Arbor.Memory.KnowledgeGraphTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.KnowledgeGraph

  @moduletag :fast

  describe "new/2" do
    test "creates a new graph with agent_id" do
      graph = KnowledgeGraph.new("agent_001")

      assert graph.agent_id == "agent_001"
      assert graph.nodes == %{}
      assert graph.edges == %{}
      assert graph.pending_facts == []
      assert graph.pending_learnings == []
    end

    test "accepts configuration options" do
      graph = KnowledgeGraph.new("agent_001", decay_rate: 0.05, max_nodes_per_type: 100)

      assert graph.config.decay_rate == 0.05
      assert graph.config.max_nodes_per_type == 100
    end
  end

  describe "add_node/2" do
    test "adds a fact node" do
      graph = KnowledgeGraph.new("agent_001")

      {:ok, new_graph, node_id} =
        KnowledgeGraph.add_node(graph, %{
          type: :fact,
          content: "The sky is blue"
        })

      assert is_binary(node_id)
      assert String.starts_with?(node_id, "node_")

      {:ok, node} = KnowledgeGraph.get_node(new_graph, node_id)
      assert node.type == :fact
      assert node.content == "The sky is blue"
      assert node.relevance == 1.0
      assert node.access_count == 0
      assert node.pinned == false
    end

    test "adds nodes of different types" do
      graph = KnowledgeGraph.new("agent_001")

      for type <- [:fact, :experience, :skill, :insight, :relationship] do
        {:ok, graph, node_id} =
          KnowledgeGraph.add_node(graph, %{
            type: type,
            content: "#{type} content"
          })

        {:ok, node} = KnowledgeGraph.get_node(graph, node_id)
        assert node.type == type
      end
    end

    test "validates required fields" do
      graph = KnowledgeGraph.new("agent_001")

      assert {:error, :missing_type} = KnowledgeGraph.add_node(graph, %{content: "test"})
      assert {:error, :missing_content} = KnowledgeGraph.add_node(graph, %{type: :fact})
    end

    test "validates node type" do
      graph = KnowledgeGraph.new("agent_001")

      assert {:error, {:invalid_type, :invalid}} =
               KnowledgeGraph.add_node(graph, %{type: :invalid, content: "test"})
    end

    test "respects quota limits" do
      graph = KnowledgeGraph.new("agent_001", max_nodes_per_type: 2)

      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "1"})
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "2"})

      assert {:error, {:quota_exceeded, :fact}} =
               KnowledgeGraph.add_node(graph, %{type: :fact, content: "3"})
    end

    test "accepts custom relevance and metadata" do
      graph = KnowledgeGraph.new("agent_001")

      {:ok, new_graph, node_id} =
        KnowledgeGraph.add_node(graph, %{
          type: :fact,
          content: "Test",
          relevance: 0.5,
          metadata: %{source: "test"},
          pinned: true
        })

      {:ok, node} = KnowledgeGraph.get_node(new_graph, node_id)
      assert node.relevance == 0.5
      assert node.metadata.source == "test"
      assert node.pinned == true
    end
  end

  describe "add_edge/5" do
    setup do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, node_a} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "A"})
      {:ok, graph, node_b} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "B"})
      %{graph: graph, node_a: node_a, node_b: node_b}
    end

    test "links two nodes", %{graph: graph, node_a: node_a, node_b: node_b} do
      {:ok, new_graph} = KnowledgeGraph.add_edge(graph, node_a, node_b, :supports)

      edges = KnowledgeGraph.get_edges(new_graph, node_a)
      assert length(edges) == 1

      [edge] = edges
      assert edge.source_id == node_a
      assert edge.target_id == node_b
      assert edge.relationship == :supports
      assert edge.strength == 1.0
    end

    test "accepts custom strength", %{graph: graph, node_a: node_a, node_b: node_b} do
      {:ok, new_graph} = KnowledgeGraph.add_edge(graph, node_a, node_b, :supports, strength: 0.5)

      [edge] = KnowledgeGraph.get_edges(new_graph, node_a)
      assert edge.strength == 0.5
    end

    test "fails for non-existent nodes", %{graph: graph, node_a: node_a} do
      assert {:error, :not_found} =
               KnowledgeGraph.add_edge(graph, node_a, "nonexistent", :supports)

      assert {:error, :not_found} =
               KnowledgeGraph.add_edge(graph, "nonexistent", node_a, :supports)
    end
  end

  describe "reinforce/2" do
    test "increases relevance and access count" do
      graph = KnowledgeGraph.new("agent_001")

      {:ok, graph, node_id} =
        KnowledgeGraph.add_node(graph, %{type: :fact, content: "Test", relevance: 0.5})

      {:ok, node} = KnowledgeGraph.get_node(graph, node_id)
      original_relevance = node.relevance

      {:ok, new_graph, reinforced_node} = KnowledgeGraph.reinforce(graph, node_id)

      assert reinforced_node.relevance > original_relevance
      assert reinforced_node.access_count == 1

      {:ok, _graph, reinforced_again} = KnowledgeGraph.reinforce(new_graph, node_id)
      assert reinforced_again.access_count == 2
    end

    test "caps relevance at 1.0" do
      graph = KnowledgeGraph.new("agent_001")

      {:ok, graph, node_id} =
        KnowledgeGraph.add_node(graph, %{
          type: :fact,
          content: "Test",
          relevance: 1.0
        })

      {:ok, _new_graph, reinforced_node} = KnowledgeGraph.reinforce(graph, node_id)
      assert reinforced_node.relevance == 1.0
    end
  end

  describe "recall/3" do
    test "finds nodes by content" do
      graph = KnowledgeGraph.new("agent_001")

      {:ok, graph, _} =
        KnowledgeGraph.add_node(graph, %{type: :fact, content: "Paris is the capital"})

      {:ok, graph, _} =
        KnowledgeGraph.add_node(graph, %{type: :fact, content: "London is a city"})

      {:ok, graph, _} =
        KnowledgeGraph.add_node(graph, %{type: :fact, content: "Tokyo is the capital"})

      {:ok, results} = KnowledgeGraph.recall(graph, "capital")

      assert length(results) == 2

      Enum.each(results, fn node ->
        assert String.contains?(String.downcase(node.content), "capital")
      end)
    end

    test "filters by type" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Test fact"})
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :skill, content: "Test skill"})

      {:ok, facts} = KnowledgeGraph.recall(graph, "test", type: :fact)
      assert length(facts) == 1
      assert hd(facts).type == :fact
    end

    test "filters by minimum relevance" do
      graph = KnowledgeGraph.new("agent_001")

      {:ok, graph, _} =
        KnowledgeGraph.add_node(graph, %{type: :fact, content: "High relevance", relevance: 0.9})

      {:ok, graph, _} =
        KnowledgeGraph.add_node(graph, %{type: :fact, content: "Low relevance", relevance: 0.1})

      {:ok, results} = KnowledgeGraph.recall(graph, "relevance", min_relevance: 0.5)

      assert length(results) == 1
      assert hd(results).content == "High relevance"
    end

    test "respects limit" do
      graph = KnowledgeGraph.new("agent_001")

      graph =
        Enum.reduce(1..10, graph, fn i, acc ->
          {:ok, new_graph, _} = KnowledgeGraph.add_node(acc, %{type: :fact, content: "Fact #{i}"})
          new_graph
        end)

      {:ok, results} = KnowledgeGraph.recall(graph, "fact", limit: 3)
      assert length(results) == 3
    end
  end

  describe "decay/1" do
    test "reduces relevance of all non-pinned nodes" do
      graph = KnowledgeGraph.new("agent_001", decay_rate: 0.1)

      {:ok, graph, node_id} =
        KnowledgeGraph.add_node(graph, %{type: :fact, content: "Test", relevance: 1.0})

      decayed_graph = KnowledgeGraph.decay(graph)

      {:ok, node} = KnowledgeGraph.get_node(decayed_graph, node_id)
      assert node.relevance == 0.9
    end

    test "does not decay pinned nodes" do
      graph = KnowledgeGraph.new("agent_001", decay_rate: 0.1)

      {:ok, graph, node_id} =
        KnowledgeGraph.add_node(graph, %{
          type: :fact,
          content: "Test",
          relevance: 1.0,
          pinned: true
        })

      decayed_graph = KnowledgeGraph.decay(graph)

      {:ok, node} = KnowledgeGraph.get_node(decayed_graph, node_id)
      assert node.relevance == 1.0
    end

    test "relevance does not go below 0" do
      graph = KnowledgeGraph.new("agent_001", decay_rate: 0.5)

      {:ok, graph, node_id} =
        KnowledgeGraph.add_node(graph, %{type: :fact, content: "Test", relevance: 0.3})

      decayed_graph = KnowledgeGraph.decay(graph)

      {:ok, node} = KnowledgeGraph.get_node(decayed_graph, node_id)
      assert node.relevance == 0.0
    end
  end

  describe "prune/2" do
    test "removes nodes below threshold" do
      graph = KnowledgeGraph.new("agent_001")

      {:ok, graph, _} =
        KnowledgeGraph.add_node(graph, %{type: :fact, content: "High", relevance: 0.8})

      {:ok, graph, _} =
        KnowledgeGraph.add_node(graph, %{type: :fact, content: "Low", relevance: 0.05})

      {pruned_graph, pruned_count} = KnowledgeGraph.prune(graph, 0.1)

      assert pruned_count == 1
      assert map_size(pruned_graph.nodes) == 1
    end

    test "does not prune pinned nodes" do
      graph = KnowledgeGraph.new("agent_001")

      {:ok, graph, _} =
        KnowledgeGraph.add_node(graph, %{
          type: :fact,
          content: "Low but pinned",
          relevance: 0.01,
          pinned: true
        })

      {pruned_graph, pruned_count} = KnowledgeGraph.prune(graph, 0.1)

      assert pruned_count == 0
      assert map_size(pruned_graph.nodes) == 1
    end

    test "removes orphaned edges" do
      graph = KnowledgeGraph.new("agent_001")

      {:ok, graph, node_a} =
        KnowledgeGraph.add_node(graph, %{type: :fact, content: "A", relevance: 0.8})

      {:ok, graph, node_b} =
        KnowledgeGraph.add_node(graph, %{type: :fact, content: "B", relevance: 0.05})

      {:ok, graph} = KnowledgeGraph.add_edge(graph, node_a, node_b, :supports)

      {pruned_graph, _} = KnowledgeGraph.prune(graph, 0.1)

      edges = KnowledgeGraph.get_edges(pruned_graph, node_a)
      assert edges == []
    end
  end

  describe "pending queues" do
    test "adds pending fact" do
      graph = KnowledgeGraph.new("agent_001")

      {:ok, new_graph, pending_id} =
        KnowledgeGraph.add_pending_fact(graph, %{
          content: "A possible fact",
          confidence: 0.7,
          source: "conversation"
        })

      assert is_binary(pending_id)
      assert length(new_graph.pending_facts) == 1
      [pending] = new_graph.pending_facts
      assert pending.content == "A possible fact"
      assert pending.confidence == 0.7
    end

    test "adds pending learning" do
      graph = KnowledgeGraph.new("agent_001")

      {:ok, new_graph, pending_id} =
        KnowledgeGraph.add_pending_learning(graph, %{
          content: "A possible skill",
          confidence: 0.6
        })

      assert is_binary(pending_id)
      assert length(new_graph.pending_learnings) == 1
    end

    test "approves pending item and creates node" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, pending_id} = KnowledgeGraph.add_pending_fact(graph, %{content: "Test fact"})

      {:ok, new_graph, node_id} = KnowledgeGraph.approve_pending(graph, pending_id)

      assert new_graph.pending_facts == []
      {:ok, node} = KnowledgeGraph.get_node(new_graph, node_id)
      assert node.content == "Test fact"
      assert node.type == :fact
    end

    test "rejects pending item" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, pending_id} = KnowledgeGraph.add_pending_fact(graph, %{content: "Test"})

      {:ok, new_graph} = KnowledgeGraph.reject_pending(graph, pending_id)

      assert new_graph.pending_facts == []
      assert map_size(new_graph.nodes) == 0
    end

    test "get_pending returns all pending items" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_pending_fact(graph, %{content: "Fact"})
      {:ok, graph, _} = KnowledgeGraph.add_pending_learning(graph, %{content: "Learning"})

      pending = KnowledgeGraph.get_pending(graph)
      assert length(pending) == 2
    end
  end

  describe "stats/1" do
    test "returns graph statistics" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, node_a} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "A"})
      {:ok, graph, node_b} = KnowledgeGraph.add_node(graph, %{type: :skill, content: "B"})
      {:ok, graph} = KnowledgeGraph.add_edge(graph, node_a, node_b, :supports)
      {:ok, graph, _} = KnowledgeGraph.add_pending_fact(graph, %{content: "Pending"})

      stats = KnowledgeGraph.stats(graph)

      assert stats.agent_id == "agent_001"
      assert stats.node_count == 2
      assert stats.nodes_by_type == %{fact: 1, skill: 1}
      assert stats.edge_count == 1
      assert stats.pending_facts == 1
      assert stats.pending_learnings == 0
      assert is_float(stats.average_relevance)
    end
  end

  describe "serialization" do
    test "to_map and from_map round-trip" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Test"})
      {:ok, graph, _} = KnowledgeGraph.add_pending_fact(graph, %{content: "Pending"})

      map = KnowledgeGraph.to_map(graph)
      restored = KnowledgeGraph.from_map(map)

      assert restored.agent_id == graph.agent_id
      assert map_size(restored.nodes) == map_size(graph.nodes)
      assert length(restored.pending_facts) == length(graph.pending_facts)
    end
  end
end
