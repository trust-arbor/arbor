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

  describe "find_by_name/2" do
    test "finds existing node by exact name" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, node_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Elixir"})

      assert {:ok, ^node_id} = KnowledgeGraph.find_by_name(graph, "Elixir")
    end

    test "case-insensitive matching" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, node_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Elixir"})

      assert {:ok, ^node_id} = KnowledgeGraph.find_by_name(graph, "elixir")
      assert {:ok, ^node_id} = KnowledgeGraph.find_by_name(graph, "ELIXIR")
    end

    test "returns not_found for missing name" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Elixir"})

      assert {:error, :not_found} = KnowledgeGraph.find_by_name(graph, "Ruby")
    end

    test "returns not_found on empty graph" do
      graph = KnowledgeGraph.new("agent_001")
      assert {:error, :not_found} = KnowledgeGraph.find_by_name(graph, "anything")
    end
  end

  # ==========================================================================
  # Group 1: Node Enhancement + Token Tracking
  # ==========================================================================

  describe "new/2 with extended options" do
    test "accepts max_active option" do
      graph = KnowledgeGraph.new("agent_001", max_active: 25)
      assert graph.max_active == 25
    end

    test "accepts dedup_threshold option" do
      graph = KnowledgeGraph.new("agent_001", dedup_threshold: 0.9)
      assert graph.dedup_threshold == 0.9
    end

    test "accepts max_tokens option" do
      graph = KnowledgeGraph.new("agent_001", max_tokens: {:fixed, 4000})
      assert graph.max_tokens == {:fixed, 4000}
    end

    test "accepts type_quotas option" do
      quotas = %{fact: 0.4, skill: 0.3, insight: 0.3}
      graph = KnowledgeGraph.new("agent_001", type_quotas: quotas)
      assert graph.type_quotas == quotas
    end

    test "has sensible defaults for new fields" do
      graph = KnowledgeGraph.new("agent_001")
      assert graph.active_set == []
      assert graph.max_active == 50
      assert graph.dedup_threshold == 0.85
      assert graph.max_tokens == nil
      assert graph.type_quotas == %{}
      assert graph.last_decay_at == nil
    end
  end

  describe "add_node/2 with confidence and token tracking" do
    test "new nodes have default confidence of 0.5" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, node_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Test"})
      {:ok, node} = KnowledgeGraph.get_node(graph, node_id)
      assert node.confidence == 0.5
    end

    test "accepts custom confidence" do
      graph = KnowledgeGraph.new("agent_001")

      {:ok, graph, node_id} =
        KnowledgeGraph.add_node(graph, %{type: :fact, content: "High confidence", confidence: 0.9})

      {:ok, node} = KnowledgeGraph.get_node(graph, node_id)
      assert node.confidence == 0.9
    end

    test "computes cached_tokens on add" do
      graph = KnowledgeGraph.new("agent_001")

      {:ok, graph, node_id} =
        KnowledgeGraph.add_node(graph, %{type: :fact, content: "This is a test sentence"})

      {:ok, node} = KnowledgeGraph.get_node(graph, node_id)
      assert node.cached_tokens > 0
    end

    test "embedding defaults to nil" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, node_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Test"})
      {:ok, node} = KnowledgeGraph.get_node(graph, node_id)
      assert node.embedding == nil
    end
  end

  describe "boost_node/3" do
    test "increases node relevance" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, node_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Test", relevance: 0.5})

      boosted = KnowledgeGraph.boost_node(graph, node_id, 0.2)
      {:ok, node} = KnowledgeGraph.get_node(boosted, node_id)
      assert_in_delta node.relevance, 0.7, 0.01
    end

    test "caps relevance at 1.0" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, node_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Test", relevance: 0.9})

      boosted = KnowledgeGraph.boost_node(graph, node_id, 0.5)
      {:ok, node} = KnowledgeGraph.get_node(boosted, node_id)
      assert node.relevance == 1.0
    end

    test "allows negative boost but floors at min_relevance" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, node_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Test", relevance: 0.1})

      boosted = KnowledgeGraph.boost_node(graph, node_id, -0.5)
      {:ok, node} = KnowledgeGraph.get_node(boosted, node_id)
      assert node.relevance == 0.01
    end

    test "updates last_accessed" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, node_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Test"})
      {:ok, original} = KnowledgeGraph.get_node(graph, node_id)

      Process.sleep(10)
      boosted = KnowledgeGraph.boost_node(graph, node_id, 0.1)
      {:ok, node} = KnowledgeGraph.get_node(boosted, node_id)
      assert DateTime.compare(node.last_accessed, original.last_accessed) in [:gt, :eq]
    end

    test "returns graph unchanged for non-existent node" do
      graph = KnowledgeGraph.new("agent_001")
      assert graph == KnowledgeGraph.boost_node(graph, "nonexistent", 0.1)
    end
  end

  describe "total_tokens/1" do
    test "returns 0 for empty graph" do
      graph = KnowledgeGraph.new("agent_001")
      assert KnowledgeGraph.total_tokens(graph) == 0
    end

    test "sums tokens across all nodes" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "First sentence here"})
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :skill, content: "Second sentence here"})

      total = KnowledgeGraph.total_tokens(graph)
      assert total > 0
    end
  end

  describe "active_set_tokens/1" do
    test "returns 0 for empty graph" do
      graph = KnowledgeGraph.new("agent_001")
      assert KnowledgeGraph.active_set_tokens(graph) == 0
    end

    test "returns token sum for nodes in active set" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Test content here"})
      assert KnowledgeGraph.active_set_tokens(graph) > 0
    end
  end

  describe "stats/1 enhanced fields" do
    test "includes token and active set stats" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, node_a} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "A"})
      {:ok, graph, node_b} = KnowledgeGraph.add_node(graph, %{type: :skill, content: "B"})
      {:ok, graph} = KnowledgeGraph.add_edge(graph, node_a, node_b, :supports)

      stats = KnowledgeGraph.stats(graph)

      assert is_integer(stats.total_tokens)
      assert stats.total_tokens > 0
      assert stats.active_set_size == 2
      assert stats.active_set_tokens > 0
      assert stats.max_active == 50
      assert stats.max_tokens == nil
      assert stats.last_decay_at == nil
      assert is_map(stats.tokens_by_type)
      assert is_map(stats.edges_by_relationship)
      assert Map.has_key?(stats.edges_by_relationship, :supports)
    end
  end

  describe "serialization with new fields" do
    test "round-trips new struct fields" do
      graph = KnowledgeGraph.new("agent_001", max_active: 30, dedup_threshold: 0.9, max_tokens: {:fixed, 2000})
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Test", confidence: 0.8})

      map = KnowledgeGraph.to_map(graph)
      restored = KnowledgeGraph.from_map(map)

      assert restored.max_active == 30
      assert restored.dedup_threshold == 0.9
      assert restored.max_tokens == {:fixed, 2000}
    end

    test "from_map handles legacy data without new fields" do
      legacy_map = %{
        "agent_id" => "agent_001",
        "nodes" => %{},
        "edges" => %{},
        "pending_facts" => [],
        "pending_learnings" => [],
        "config" => %{"decay_rate" => 0.1, "max_nodes_per_type" => 500, "prune_threshold" => 0.1}
      }

      restored = KnowledgeGraph.from_map(legacy_map)
      assert restored.agent_id == "agent_001"
      assert restored.max_active == 50
      assert restored.dedup_threshold == 0.85
      assert restored.active_set == []
    end

    test "node confidence and cached_tokens survive round-trip" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, node_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Test", confidence: 0.9})
      {:ok, original} = KnowledgeGraph.get_node(graph, node_id)

      map = KnowledgeGraph.to_map(graph)
      restored = KnowledgeGraph.from_map(map)
      {:ok, restored_node} = KnowledgeGraph.get_node(restored, node_id)

      assert restored_node.confidence == original.confidence
      assert restored_node.cached_tokens == original.cached_tokens
    end
  end

  # ==========================================================================
  # Group 2: Active Set Management
  # ==========================================================================

  describe "active set auto-population" do
    test "add_node adds to active set when relevance >= 0.01" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, node_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Test"})

      assert node_id in graph.active_set
    end

    test "reinforce updates active set" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, node_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Test", relevance: 0.5})

      {:ok, graph, _} = KnowledgeGraph.reinforce(graph, node_id)
      assert node_id in graph.active_set
    end

    test "boost_node updates active set" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, node_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Test", relevance: 0.5})

      graph = KnowledgeGraph.boost_node(graph, node_id, 0.1)
      assert node_id in graph.active_set
    end

    test "remove_node cleans active set" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, node_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Test"})
      assert node_id in graph.active_set

      {:ok, graph} = KnowledgeGraph.remove_node(graph, node_id)
      refute node_id in graph.active_set
    end

    test "prune cleans active set" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, kept_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "High", relevance: 0.8})
      {:ok, graph, pruned_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Low", relevance: 0.05})

      assert pruned_id in graph.active_set

      {graph, _} = KnowledgeGraph.prune(graph, 0.1)
      assert kept_id in graph.active_set
      refute pruned_id in graph.active_set
    end

    test "evicts lowest-relevance when over max_active" do
      graph = KnowledgeGraph.new("agent_001", max_active: 3)

      {:ok, graph, id1} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "First", relevance: 0.5})
      {:ok, graph, id2} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Second", relevance: 0.7})
      {:ok, graph, id3} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Third", relevance: 0.9})

      assert length(graph.active_set) == 3

      # Adding a 4th should evict the lowest (id1 at 0.5)
      {:ok, graph, id4} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Fourth", relevance: 0.8})

      assert length(graph.active_set) == 3
      assert id4 in graph.active_set
      assert id3 in graph.active_set
      assert id2 in graph.active_set
      refute id1 in graph.active_set
    end
  end

  describe "active_set/2" do
    test "returns nodes sorted by relevance descending" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Low", relevance: 0.3})
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "High", relevance: 0.9})
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Mid", relevance: 0.6})

      nodes = KnowledgeGraph.active_set(graph)
      relevances = Enum.map(nodes, & &1.relevance)
      assert relevances == Enum.sort(relevances, :desc)
    end

    test "returns empty list for empty graph" do
      graph = KnowledgeGraph.new("agent_001")
      assert KnowledgeGraph.active_set(graph) == []
    end
  end

  describe "select_by_token_budget/3" do
    test "selects nodes within budget" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "A short fact"})
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Another short fact"})
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Third fact here"})

      all_nodes = graph.nodes |> Map.values() |> Enum.sort_by(& &1.relevance, :desc)
      total = Enum.reduce(all_nodes, 0, &(&1.cached_tokens + &2))

      # Give enough budget for all
      selected = KnowledgeGraph.select_by_token_budget(all_nodes, total + 100)
      assert length(selected) == 3

      # Restrict budget to only fit 1 node
      first_tokens = hd(all_nodes).cached_tokens
      selected = KnowledgeGraph.select_by_token_budget(all_nodes, first_tokens)
      assert length(selected) == 1
    end

    test "respects type quotas" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Fact one about a topic that is fairly long", relevance: 0.9})
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Fact two about another topic that is also long", relevance: 0.8})
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :skill, content: "Skill one about something lengthy as well", relevance: 0.7})

      all_nodes = graph.nodes |> Map.values() |> Enum.sort_by(& &1.relevance, :desc)

      # Set fact quota to 0 tokens — no facts should be selected
      quotas = %{fact: 0.0}
      selected = KnowledgeGraph.select_by_token_budget(all_nodes, 10_000, quotas)

      fact_count = Enum.count(selected, &(&1.type == :fact))
      skill_count = Enum.count(selected, &(&1.type == :skill))
      assert fact_count == 0
      assert skill_count == 1
    end
  end

  describe "refresh_active_set/1" do
    test "recomputes active set from all nodes" do
      graph = KnowledgeGraph.new("agent_001", max_active: 2)
      {:ok, graph, id1} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "A", relevance: 0.3})
      {:ok, graph, id2} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "B", relevance: 0.9})
      {:ok, graph, id3} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "C", relevance: 0.6})

      # After adds, active_set should have max_active=2 nodes
      assert length(graph.active_set) == 2

      refreshed = KnowledgeGraph.refresh_active_set(graph)
      assert length(refreshed.active_set) == 2
      assert id2 in refreshed.active_set
      assert id3 in refreshed.active_set
      refute id1 in refreshed.active_set
    end
  end

  describe "promote_to_active/2" do
    test "adds node to active set" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, node_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Test"})

      # Clear active set manually to test promote
      graph = %{graph | active_set: []}
      refute node_id in graph.active_set

      graph = KnowledgeGraph.promote_to_active(graph, node_id)
      assert node_id in graph.active_set
    end

    test "no-op for non-existent node" do
      graph = KnowledgeGraph.new("agent_001")
      assert graph == KnowledgeGraph.promote_to_active(graph, "nonexistent")
    end
  end

  # ==========================================================================
  # Group 3: Exponential Decay + Archival
  # ==========================================================================

  describe "apply_decay/2" do
    test "applies exponential decay based on time since access" do
      graph = KnowledgeGraph.new("agent_001", decay_rate: 0.1)
      {:ok, graph, node_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Test", relevance: 1.0})

      # Manually set last_accessed to 10 days ago
      ten_days_ago = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)
      old_node = %{graph.nodes[node_id] | last_accessed: ten_days_ago}
      graph = %{graph | nodes: Map.put(graph.nodes, node_id, old_node)}

      decayed = KnowledgeGraph.apply_decay(graph)
      {:ok, node} = KnowledgeGraph.get_node(decayed, node_id)

      # With λ=0.1, 10 days: e^(-0.1 * 10) ≈ 0.368
      assert node.relevance < 0.5
      assert node.relevance > 0.3
    end

    test "does not decay pinned nodes" do
      graph = KnowledgeGraph.new("agent_001", decay_rate: 0.5)

      {:ok, graph, node_id} =
        KnowledgeGraph.add_node(graph, %{type: :fact, content: "Pinned", relevance: 1.0, pinned: true})

      ten_days_ago = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)
      old_node = %{graph.nodes[node_id] | last_accessed: ten_days_ago}
      graph = %{graph | nodes: Map.put(graph.nodes, node_id, old_node)}

      decayed = KnowledgeGraph.apply_decay(graph)
      {:ok, node} = KnowledgeGraph.get_node(decayed, node_id)
      assert node.relevance == 1.0
    end

    test "respects pinned_ids option" do
      graph = KnowledgeGraph.new("agent_001", decay_rate: 0.5)
      {:ok, graph, node_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Protected", relevance: 1.0})

      ten_days_ago = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)
      old_node = %{graph.nodes[node_id] | last_accessed: ten_days_ago}
      graph = %{graph | nodes: Map.put(graph.nodes, node_id, old_node)}

      decayed = KnowledgeGraph.apply_decay(graph, pinned_ids: [node_id])
      {:ok, node} = KnowledgeGraph.get_node(decayed, node_id)
      assert node.relevance == 1.0
    end

    test "floors relevance at min_relevance (0.01)" do
      graph = KnowledgeGraph.new("agent_001", decay_rate: 1.0)
      {:ok, graph, node_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Test", relevance: 0.1})

      hundred_days_ago = DateTime.add(DateTime.utc_now(), -100 * 86_400, :second)
      old_node = %{graph.nodes[node_id] | last_accessed: hundred_days_ago}
      graph = %{graph | nodes: Map.put(graph.nodes, node_id, old_node)}

      decayed = KnowledgeGraph.apply_decay(graph)
      {:ok, node} = KnowledgeGraph.get_node(decayed, node_id)
      assert node.relevance == 0.01
    end

    test "sets last_decay_at" do
      graph = KnowledgeGraph.new("agent_001")
      assert graph.last_decay_at == nil

      decayed = KnowledgeGraph.apply_decay(graph)
      assert decayed.last_decay_at != nil
    end

    test "refreshes active set after decay" do
      graph = KnowledgeGraph.new("agent_001", max_active: 2, decay_rate: 1.0)
      {:ok, graph, id1} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Old", relevance: 0.5})
      {:ok, graph, id2} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Recent", relevance: 0.5})

      # Make id1 very old so it decays heavily
      old = DateTime.add(DateTime.utc_now(), -50 * 86_400, :second)
      old_node = %{graph.nodes[id1] | last_accessed: old}
      graph = %{graph | nodes: Map.put(graph.nodes, id1, old_node)}

      decayed = KnowledgeGraph.apply_decay(graph)
      # id2 (recently accessed) should still be in active set
      assert id2 in decayed.active_set
    end
  end

  describe "prune_and_archive/2" do
    test "removes low-relevance nodes and returns count" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "High", relevance: 0.8})
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Low", relevance: 0.05})

      {pruned, count} = KnowledgeGraph.prune_and_archive(graph)
      assert count == 1
      assert map_size(pruned.nodes) == 1
    end

    test "accepts custom threshold" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Mid", relevance: 0.5})

      {_, count} = KnowledgeGraph.prune_and_archive(graph, threshold: 0.6)
      assert count == 1
    end

    test "does not archive pinned nodes" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Pinned", relevance: 0.01, pinned: true})

      {_, count} = KnowledgeGraph.prune_and_archive(graph)
      assert count == 0
    end

    test "cleans active set" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, low_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Low", relevance: 0.05})
      assert low_id in graph.active_set

      {pruned, _} = KnowledgeGraph.prune_and_archive(graph)
      refute low_id in pruned.active_set
    end
  end

  describe "decay_and_archive/2" do
    test "skips when under capacity" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Test"})

      {result, count} = KnowledgeGraph.decay_and_archive(graph)
      assert count == 0
      assert result == graph
    end

    test "runs when force: true even under capacity" do
      graph = KnowledgeGraph.new("agent_001", decay_rate: 1.0)
      {:ok, graph, node_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Old", relevance: 0.2})

      old = DateTime.add(DateTime.utc_now(), -50 * 86_400, :second)
      old_node = %{graph.nodes[node_id] | last_accessed: old}
      graph = %{graph | nodes: Map.put(graph.nodes, node_id, old_node)}

      {result, count} = KnowledgeGraph.decay_and_archive(graph, force: true)
      # The node should have been decayed to near min_relevance and then pruned
      assert count == 1
      assert map_size(result.nodes) == 0
    end
  end

  # ==========================================================================
  # Group 4: Semantic Dedup + Search + Edge Enhancements
  # ==========================================================================

  describe "add_node/2 exact dedup" do
    test "detects exact content duplicate and boosts existing" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, id1} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "The sky is blue", relevance: 0.5})
      {:ok, original} = KnowledgeGraph.get_node(graph, id1)

      # Add same content again
      {:ok, graph, id2} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "The sky is blue"})

      # Should return existing node ID
      assert id1 == id2
      # Should have boosted it
      {:ok, boosted} = KnowledgeGraph.get_node(graph, id1)
      assert boosted.relevance > original.relevance
    end

    test "skip_dedup bypasses deduplication" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, id1} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Duplicate"})
      {:ok, graph, id2} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Duplicate", skip_dedup: true})

      assert id1 != id2
      assert map_size(graph.nodes) == 2
    end

    test "different types are not considered duplicates" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, id1} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Learning Elixir"})
      {:ok, graph, id2} = KnowledgeGraph.add_node(graph, %{type: :skill, content: "Learning Elixir"})

      assert id1 != id2
      assert map_size(graph.nodes) == 2
    end
  end

  describe "add_edge/5 strength merging" do
    setup do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, node_a} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "A"})
      {:ok, graph, node_b} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "B"})
      %{graph: graph, node_a: node_a, node_b: node_b}
    end

    test "increments strength on duplicate edge", %{graph: graph, node_a: a, node_b: b} do
      {:ok, graph} = KnowledgeGraph.add_edge(graph, a, b, :supports)
      [edge] = KnowledgeGraph.get_edges(graph, a)
      assert edge.strength == 1.0

      {:ok, graph} = KnowledgeGraph.add_edge(graph, a, b, :supports)
      edges = KnowledgeGraph.get_edges(graph, a)
      # Should still be 1 edge, not 2
      assert length(edges) == 1
      [edge] = edges
      assert edge.strength == 1.5
    end

    test "caps strength at 10.0", %{graph: graph, node_a: a, node_b: b} do
      {:ok, graph} = KnowledgeGraph.add_edge(graph, a, b, :supports, strength: 9.8)
      {:ok, graph} = KnowledgeGraph.add_edge(graph, a, b, :supports)
      [edge] = KnowledgeGraph.get_edges(graph, a)
      assert edge.strength == 10.0
    end

    test "different relationships create separate edges", %{graph: graph, node_a: a, node_b: b} do
      {:ok, graph} = KnowledgeGraph.add_edge(graph, a, b, :supports)
      {:ok, graph} = KnowledgeGraph.add_edge(graph, a, b, :contradicts)
      edges = KnowledgeGraph.get_edges(graph, a)
      assert length(edges) == 2
    end
  end

  describe "edges_to/2" do
    test "finds incoming edges" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, a} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "A"})
      {:ok, graph, b} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "B"})
      {:ok, graph, c} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "C"})

      {:ok, graph} = KnowledgeGraph.add_edge(graph, a, b, :supports)
      {:ok, graph} = KnowledgeGraph.add_edge(graph, c, b, :relates_to)

      incoming = KnowledgeGraph.edges_to(graph, b)
      assert length(incoming) == 2
      assert Enum.all?(incoming, &(&1.target_id == b))
    end

    test "returns empty for no incoming edges" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, a} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "A"})
      assert KnowledgeGraph.edges_to(graph, a) == []
    end
  end

  describe "unlink/4" do
    test "removes matching edge" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, a} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "A"})
      {:ok, graph, b} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "B"})
      {:ok, graph} = KnowledgeGraph.add_edge(graph, a, b, :supports)

      assert length(KnowledgeGraph.get_edges(graph, a)) == 1

      {:ok, graph} = KnowledgeGraph.unlink(graph, a, b, :supports)
      assert KnowledgeGraph.get_edges(graph, a) == []
    end

    test "returns error for non-existent edge" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, a} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "A"})
      {:ok, graph, b} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "B"})

      assert {:error, :not_found} = KnowledgeGraph.unlink(graph, a, b, :supports)
    end
  end

  describe "semantic_search/3" do
    test "finds nodes by keyword matching" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Paris is the capital of France", skip_dedup: true})
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "London is a city in England", skip_dedup: true})
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Tokyo is the capital of Japan", skip_dedup: true})

      {:ok, results} = KnowledgeGraph.semantic_search(graph, "capital")
      assert length(results) == 2
      Enum.each(results, fn node ->
        assert String.contains?(String.downcase(node.content), "capital")
      end)
    end

    test "filters by types" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Elixir is functional", skip_dedup: true})
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :skill, content: "Elixir pattern matching", skip_dedup: true})

      {:ok, results} = KnowledgeGraph.semantic_search(graph, "elixir", types: [:fact])
      assert length(results) == 1
      assert hd(results).type == :fact
    end

    test "respects limit" do
      graph = KnowledgeGraph.new("agent_001")

      graph =
        Enum.reduce(1..5, graph, fn i, acc ->
          {:ok, g, _} = KnowledgeGraph.add_node(acc, %{type: :fact, content: "Fact #{i}", skip_dedup: true})
          g
        end)

      {:ok, results} = KnowledgeGraph.semantic_search(graph, "fact", limit: 2)
      assert length(results) == 2
    end

    test "respects min_relevance" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "High fact", relevance: 0.9, skip_dedup: true})
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Low fact", relevance: 0.1, skip_dedup: true})

      {:ok, results} = KnowledgeGraph.semantic_search(graph, "fact", min_relevance: 0.5)
      assert length(results) == 1
      assert hd(results).relevance == 0.9
    end
  end

  # ==========================================================================
  # Group 5: Cascade Recall + Context Gen + Query Helpers
  # ==========================================================================

  describe "cascade_recall/4" do
    test "boosts starting node and neighbors" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, a} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "A", relevance: 0.5, skip_dedup: true})
      {:ok, graph, b} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "B", relevance: 0.3, skip_dedup: true})
      {:ok, graph, c} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "C", relevance: 0.2, skip_dedup: true})
      {:ok, graph} = KnowledgeGraph.add_edge(graph, a, b, :supports)
      {:ok, graph} = KnowledgeGraph.add_edge(graph, b, c, :supports)

      cascaded = KnowledgeGraph.cascade_recall(graph, a, 0.2)

      {:ok, node_a} = KnowledgeGraph.get_node(cascaded, a)
      {:ok, node_b} = KnowledgeGraph.get_node(cascaded, b)
      {:ok, node_c} = KnowledgeGraph.get_node(cascaded, c)

      # A gets full boost, B gets half, C gets quarter
      assert node_a.relevance > 0.5
      assert node_b.relevance > 0.3
      assert node_c.relevance > 0.2
    end

    test "respects max_depth" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, a} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "A", relevance: 0.5, skip_dedup: true})
      {:ok, graph, b} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "B", relevance: 0.3, skip_dedup: true})
      {:ok, graph, c} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "C", relevance: 0.2, skip_dedup: true})
      {:ok, graph} = KnowledgeGraph.add_edge(graph, a, b, :supports)
      {:ok, graph} = KnowledgeGraph.add_edge(graph, b, c, :supports)

      # max_depth 2 means A + immediate neighbors (B), but not C
      cascaded = KnowledgeGraph.cascade_recall(graph, a, 0.2, max_depth: 2)

      {:ok, node_a} = KnowledgeGraph.get_node(cascaded, a)
      {:ok, node_b} = KnowledgeGraph.get_node(cascaded, b)
      {:ok, node_c} = KnowledgeGraph.get_node(cascaded, c)

      assert node_a.relevance > 0.5
      assert node_b.relevance > 0.3
      # C should be unchanged (depth limited — boost at depth 3 would be 0.05 * 0.5 = 0.025 < min_boost)
      assert_in_delta node_c.relevance, 0.2, 0.06
    end

    test "no-op for isolated node" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, a} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Alone", relevance: 0.5, skip_dedup: true})

      cascaded = KnowledgeGraph.cascade_recall(graph, a, 0.2)
      {:ok, node} = KnowledgeGraph.get_node(cascaded, a)
      assert_in_delta node.relevance, 0.7, 0.01
    end
  end

  describe "to_prompt_text/2" do
    test "generates formatted text from active set" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Paris is capital of France", relevance: 0.9, skip_dedup: true})
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :skill, content: "Pattern matching", relevance: 0.7, skip_dedup: true})

      text = KnowledgeGraph.to_prompt_text(graph)
      assert String.contains?(text, "[fact]")
      assert String.contains?(text, "[skill]")
      assert String.contains?(text, "relevance")
      assert String.contains?(text, "Paris")
    end

    test "includes relationships when enabled" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, a} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "A", skip_dedup: true})
      {:ok, graph, b} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "B", skip_dedup: true})
      {:ok, graph} = KnowledgeGraph.add_edge(graph, a, b, :supports)

      text = KnowledgeGraph.to_prompt_text(graph, include_relationships: true)
      assert String.contains?(text, "supports")
    end

    test "excludes relationships when disabled" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, a} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "A", skip_dedup: true})
      {:ok, graph, b} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "B", skip_dedup: true})
      {:ok, graph} = KnowledgeGraph.add_edge(graph, a, b, :supports)

      text = KnowledgeGraph.to_prompt_text(graph, include_relationships: false)
      refute String.contains?(text, "supports")
    end

    test "returns empty string for empty graph" do
      graph = KnowledgeGraph.new("agent_001")
      assert KnowledgeGraph.to_prompt_text(graph) == ""
    end
  end

  describe "find_by_type/2" do
    test "delegates to list_by_type" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Fact 1", skip_dedup: true})
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :skill, content: "Skill 1", skip_dedup: true})

      facts = KnowledgeGraph.find_by_type(graph, :fact)
      assert length(facts) == 1
      assert hd(facts).type == :fact
    end
  end

  describe "find_by_type_and_criteria/4" do
    test "filters by type and custom function" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "High fact", relevance: 0.9, skip_dedup: true})
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Low fact", relevance: 0.2, skip_dedup: true})

      results = KnowledgeGraph.find_by_type_and_criteria(graph, :fact, &(&1.relevance > 0.5))
      assert length(results) == 1
      assert hd(results).content == "High fact"
    end

    test "respects limit" do
      graph = KnowledgeGraph.new("agent_001")

      graph =
        Enum.reduce(1..5, graph, fn i, acc ->
          {:ok, g, _} = KnowledgeGraph.add_node(acc, %{type: :fact, content: "Fact #{i}", skip_dedup: true})
          g
        end)

      results = KnowledgeGraph.find_by_type_and_criteria(graph, :fact, fn _ -> true end, limit: 2)
      assert length(results) == 2
    end
  end

  describe "recent_nodes/2" do
    test "returns nodes sorted by recency" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "First", skip_dedup: true})
      Process.sleep(10)
      {:ok, graph, id2} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Second", skip_dedup: true})

      results = KnowledgeGraph.recent_nodes(graph)
      assert length(results) == 2
      # Most recent first
      assert hd(results).id == id2
    end

    test "filters by types" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "A fact", skip_dedup: true})
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :skill, content: "A skill", skip_dedup: true})

      results = KnowledgeGraph.recent_nodes(graph, types: [:skill])
      assert length(results) == 1
      assert hd(results).type == :skill
    end

    test "respects limit" do
      graph = KnowledgeGraph.new("agent_001")

      graph =
        Enum.reduce(1..10, graph, fn i, acc ->
          {:ok, g, _} = KnowledgeGraph.add_node(acc, %{type: :fact, content: "N #{i}", skip_dedup: true})
          g
        end)

      results = KnowledgeGraph.recent_nodes(graph, limit: 3)
      assert length(results) == 3
    end
  end

  describe "get_tool_learnings/1,2" do
    test "groups skill nodes by tool_name" do
      graph = KnowledgeGraph.new("agent_001")

      {:ok, graph, _} =
        KnowledgeGraph.add_node(graph, %{
          type: :skill,
          content: "Git rebase technique",
          metadata: %{tool_name: "git"},
          skip_dedup: true
        })

      {:ok, graph, _} =
        KnowledgeGraph.add_node(graph, %{
          type: :skill,
          content: "Git cherry-pick",
          metadata: %{tool_name: "git"},
          skip_dedup: true
        })

      {:ok, graph, _} =
        KnowledgeGraph.add_node(graph, %{
          type: :skill,
          content: "Docker compose",
          metadata: %{tool_name: "docker"},
          skip_dedup: true
        })

      learnings = KnowledgeGraph.get_tool_learnings(graph)
      assert length(learnings["git"]) == 2
      assert length(learnings["docker"]) == 1
    end

    test "get_tool_learnings/2 filters by specific tool" do
      graph = KnowledgeGraph.new("agent_001")

      {:ok, graph, _} =
        KnowledgeGraph.add_node(graph, %{
          type: :skill,
          content: "Git trick",
          metadata: %{tool_name: "git"},
          skip_dedup: true
        })

      {:ok, graph, _} =
        KnowledgeGraph.add_node(graph, %{
          type: :skill,
          content: "Docker trick",
          metadata: %{tool_name: "docker"},
          skip_dedup: true
        })

      git_learnings = KnowledgeGraph.get_tool_learnings(graph, "git")
      assert length(git_learnings) == 1
      assert hd(git_learnings).content == "Git trick"
    end
  end

  # ============================================================================
  # Gap Fill Tests — Changes 1-6
  # ============================================================================

  describe "find_related/3 (Change 1)" do
    test "returns direct neighbors at depth 1" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, a_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Node A", skip_dedup: true})
      {:ok, graph, b_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Node B", skip_dedup: true})
      {:ok, graph, _c_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Node C", skip_dedup: true})
      {:ok, graph} = KnowledgeGraph.add_edge(graph, a_id, b_id, :relates_to)

      related = KnowledgeGraph.find_related(graph, a_id, depth: 1)
      assert length(related) == 1
      assert hd(related).id == b_id
    end

    test "returns multi-hop neighbors at depth 2" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, a_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Node A", skip_dedup: true})
      {:ok, graph, b_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Node B", skip_dedup: true})
      {:ok, graph, c_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Node C", skip_dedup: true})
      {:ok, graph} = KnowledgeGraph.add_edge(graph, a_id, b_id, :relates_to)
      {:ok, graph} = KnowledgeGraph.add_edge(graph, b_id, c_id, :relates_to)

      related = KnowledgeGraph.find_related(graph, a_id, depth: 2)
      ids = Enum.map(related, & &1.id)
      assert b_id in ids
      assert c_id in ids
    end

    test "returns deep chain at depth 3" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, a_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "A deep", skip_dedup: true})
      {:ok, graph, b_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "B deep", skip_dedup: true})
      {:ok, graph, c_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "C deep", skip_dedup: true})
      {:ok, graph, d_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "D deep", skip_dedup: true})
      {:ok, graph} = KnowledgeGraph.add_edge(graph, a_id, b_id, :relates_to)
      {:ok, graph} = KnowledgeGraph.add_edge(graph, b_id, c_id, :relates_to)
      {:ok, graph} = KnowledgeGraph.add_edge(graph, c_id, d_id, :relates_to)

      related = KnowledgeGraph.find_related(graph, a_id, depth: 3)
      ids = Enum.map(related, & &1.id)
      assert b_id in ids
      assert c_id in ids
      assert d_id in ids
    end

    test "filters by relationship type" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, a_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Center node", skip_dedup: true})
      {:ok, graph, b_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Related node", skip_dedup: true})
      {:ok, graph, c_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Other node", skip_dedup: true})
      {:ok, graph} = KnowledgeGraph.add_edge(graph, a_id, b_id, :causes)
      {:ok, graph} = KnowledgeGraph.add_edge(graph, a_id, c_id, :relates_to)

      related = KnowledgeGraph.find_related(graph, a_id, depth: 1, relationship: :causes)
      assert length(related) == 1
      assert hd(related).id == b_id
    end

    test "returns empty list for isolated node" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, a_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Isolated", skip_dedup: true})

      assert KnowledgeGraph.find_related(graph, a_id) == []
    end

    test "returns empty list for unknown node" do
      graph = KnowledgeGraph.new("agent_001")
      assert KnowledgeGraph.find_related(graph, "nonexistent") == []
    end

    test "results are sorted by relevance descending" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, a_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Center sorted", skip_dedup: true})
      {:ok, graph, b_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Low relevance", relevance: 0.3, skip_dedup: true})
      {:ok, graph, c_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "High relevance", relevance: 0.9, skip_dedup: true})
      {:ok, graph} = KnowledgeGraph.add_edge(graph, a_id, b_id, :relates_to)
      {:ok, graph} = KnowledgeGraph.add_edge(graph, a_id, c_id, :relates_to)

      related = KnowledgeGraph.find_related(graph, a_id, depth: 1)
      assert length(related) == 2
      [first, second] = related
      assert first.relevance >= second.relevance
    end

    test "excludes starting node from results" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, a_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Start node", skip_dedup: true})
      {:ok, graph, b_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Neighbor", skip_dedup: true})
      {:ok, graph} = KnowledgeGraph.add_edge(graph, a_id, b_id, :relates_to)

      related = KnowledgeGraph.find_related(graph, a_id, depth: 1)
      ids = Enum.map(related, & &1.id)
      refute a_id in ids
    end

    test "get_connected_nodes/2 delegates to find_related depth 1" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, a_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Compat center", skip_dedup: true})
      {:ok, graph, b_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Compat neighbor", skip_dedup: true})
      {:ok, graph} = KnowledgeGraph.add_edge(graph, a_id, b_id, :relates_to)

      assert KnowledgeGraph.get_connected_nodes(graph, a_id) == KnowledgeGraph.find_related(graph, a_id, depth: 1)
    end
  end

  describe "cognitive preferences in active_set (Change 2)" do
    test "active_set without preferences works unchanged" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "No prefs test", skip_dedup: true})

      nodes = KnowledgeGraph.active_set(graph)
      assert length(nodes) == 1
    end

    test "cognitive preferences override type quotas" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Fact for prefs override test content", skip_dedup: true})
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :insight, content: "Insight for prefs override test content", skip_dedup: true})

      # Without preferences — both types present
      all_nodes = KnowledgeGraph.active_set(graph, model_context: {:fixed, 5000})
      all_types = Enum.map(all_nodes, & &1.type)
      assert :fact in all_types
      assert :insight in all_types

      # With cognitive preferences that give 0% to facts — facts excluded
      prefs = %{type_quotas: %{fact: 0.0, insight: 1.0}}
      nodes = KnowledgeGraph.active_set(graph, model_context: {:fixed, 5000}, cognitive_preferences: prefs)
      types = Enum.map(nodes, & &1.type)
      refute :fact in types
      assert :insight in types
    end

    test "nil cognitive preferences leaves quotas unchanged" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Nil prefs test", skip_dedup: true})

      nodes = KnowledgeGraph.active_set(graph, cognitive_preferences: nil)
      assert length(nodes) == 1
    end

    test "empty preferences map leaves quotas unchanged" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Empty prefs test", skip_dedup: true})

      nodes = KnowledgeGraph.active_set(graph, cognitive_preferences: %{})
      assert length(nodes) == 1
    end
  end

  describe "batch approval and pending getters (Change 3)" do
    test "get_pending_facts returns only facts" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_pending_fact(graph, %{content: "Test fact for getter"})
      {:ok, graph, _} = KnowledgeGraph.add_pending_learning(graph, %{content: "Test learning for getter"})

      facts = KnowledgeGraph.get_pending_facts(graph)
      assert length(facts) == 1
      assert hd(facts).content == "Test fact for getter"
    end

    test "get_pending_learnings returns only learnings" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_pending_fact(graph, %{content: "Fact for learning getter"})
      {:ok, graph, _} = KnowledgeGraph.add_pending_learning(graph, %{content: "Learning for getter"})

      learnings = KnowledgeGraph.get_pending_learnings(graph)
      assert length(learnings) == 1
      assert hd(learnings).content == "Learning for getter"
    end

    test "approve_all_facts approves all pending facts" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_pending_fact(graph, %{content: "Batch fact 1"})
      {:ok, graph, _} = KnowledgeGraph.add_pending_fact(graph, %{content: "Batch fact 2"})
      {:ok, graph, _} = KnowledgeGraph.add_pending_learning(graph, %{content: "Should remain learning"})

      {:ok, graph, ids} = KnowledgeGraph.approve_all_facts(graph)
      assert length(ids) == 2
      assert graph.pending_facts == []
      # Learning should still be pending
      assert length(graph.pending_learnings) == 1
    end

    test "approve_all_learnings approves all pending learnings" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_pending_learning(graph, %{content: "Batch learning 1"})
      {:ok, graph, _} = KnowledgeGraph.add_pending_learning(graph, %{content: "Batch learning 2"})
      {:ok, graph, _} = KnowledgeGraph.add_pending_fact(graph, %{content: "Should remain fact"})

      {:ok, graph, ids} = KnowledgeGraph.approve_all_learnings(graph)
      assert length(ids) == 2
      assert graph.pending_learnings == []
      # Fact should still be pending
      assert length(graph.pending_facts) == 1
    end

    test "approve_all_facts on empty queue returns empty" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, ids} = KnowledgeGraph.approve_all_facts(graph)
      assert ids == []
      assert graph == KnowledgeGraph.new("agent_001")
    end

    test "approve_all_learnings on empty queue returns empty" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, ids} = KnowledgeGraph.approve_all_learnings(graph)
      assert ids == []
      assert graph == KnowledgeGraph.new("agent_001")
    end
  end

  describe "search_by_name/2 (Change 4)" do
    test "finds nodes by substring match" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Elixir is great", skip_dedup: true})
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Elixir patterns", skip_dedup: true})
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Rust is fast", skip_dedup: true})

      results = KnowledgeGraph.search_by_name(graph, "Elixir")
      assert length(results) == 2
      assert Enum.all?(results, fn n -> String.contains?(n.content, "Elixir") end)
    end

    test "search is case-insensitive" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "UPPERCASE content", skip_dedup: true})

      results = KnowledgeGraph.search_by_name(graph, "uppercase")
      assert length(results) == 1
    end

    test "results sorted by relevance descending" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "search target low", relevance: 0.3, skip_dedup: true})
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "search target high", relevance: 0.9, skip_dedup: true})

      results = KnowledgeGraph.search_by_name(graph, "search target")
      assert length(results) == 2
      [first, second] = results
      assert first.relevance >= second.relevance
    end

    test "returns empty list when no matches" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Something else", skip_dedup: true})

      assert KnowledgeGraph.search_by_name(graph, "nonexistent") == []
    end
  end

  describe "to_prompt_text enhancements (Change 5)" do
    test "includes markdown header when nodes exist" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Header test node", skip_dedup: true})

      text = KnowledgeGraph.to_prompt_text(graph)
      assert String.starts_with?(text, "## Knowledge Graph (Active Context)")
    end

    test "returns empty string for empty graph" do
      graph = KnowledgeGraph.new("agent_001")
      assert KnowledgeGraph.to_prompt_text(graph) == ""
    end

    test "uses 4-space indentation for nodes" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, _} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Indented node", skip_dedup: true})

      text = KnowledgeGraph.to_prompt_text(graph, include_relationships: false)
      assert text =~ "    - [fact] Indented node"
    end

    test "includes incoming edges with arrow prefix" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, a_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Source node", skip_dedup: true})
      {:ok, graph, b_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Target node", skip_dedup: true})
      {:ok, graph} = KnowledgeGraph.add_edge(graph, a_id, b_id, :causes)

      text = KnowledgeGraph.to_prompt_text(graph)
      # Target should show incoming edge from source
      assert text =~ "← causes: Source node"
      # Source should show outgoing edge to target
      assert text =~ "→ causes: Target node"
    end
  end

  describe "cascade_recall decay factor (Change 6)" do
    test "default decay factor (0.5) works as before" do
      graph = KnowledgeGraph.new("agent_001")
      {:ok, graph, a_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Cascade center default", relevance: 0.5, skip_dedup: true})
      {:ok, graph, b_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Cascade neighbor default", relevance: 0.3, skip_dedup: true})
      {:ok, graph} = KnowledgeGraph.add_edge(graph, a_id, b_id, :relates_to)

      original_b = Map.get(graph.nodes, b_id)
      graph = KnowledgeGraph.cascade_recall(graph, a_id, 0.2, max_depth: 2)
      updated_b = Map.get(graph.nodes, b_id)

      # Neighbor should be boosted by 0.2 * 0.5 = 0.1
      assert_in_delta updated_b.relevance, original_b.relevance + 0.1, 0.01
    end

    test "custom decay factor produces different spread" do
      # Build identical graphs
      build_graph = fn ->
        graph = KnowledgeGraph.new("agent_001")
        {:ok, graph, a_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Decay center custom", relevance: 0.3, skip_dedup: true})
        {:ok, graph, b_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Decay neighbor custom", relevance: 0.3, skip_dedup: true})
        {:ok, graph} = KnowledgeGraph.add_edge(graph, a_id, b_id, :relates_to)
        {graph, a_id, b_id}
      end

      {graph1, a1, b1} = build_graph.()
      {graph2, a2, b2} = build_graph.()

      # Default decay (0.5): neighbor gets 0.2 * 0.5 = 0.1
      graph1 = KnowledgeGraph.cascade_recall(graph1, a1, 0.2, max_depth: 2)
      # Lower decay (0.3): neighbor gets 0.2 * 0.3 = 0.06
      graph2 = KnowledgeGraph.cascade_recall(graph2, a2, 0.2, max_depth: 2, decay_factor: 0.3)

      b1_relevance = Map.get(graph1.nodes, b1).relevance
      b2_relevance = Map.get(graph2.nodes, b2).relevance

      # Lower decay = less spread to neighbors
      assert b1_relevance > b2_relevance
    end
  end
end
