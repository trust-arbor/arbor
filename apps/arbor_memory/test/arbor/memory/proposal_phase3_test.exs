defmodule Arbor.Memory.ProposalPhase3Test do
  use ExUnit.Case, async: true

  alias Arbor.Memory.{KnowledgeGraph, Proposal}

  @moduletag :fast

  setup do
    ensure_ets_tables()
    agent_id = "test_agent_p3_#{System.unique_integer([:positive])}"
    graph = KnowledgeGraph.new(agent_id)
    :ets.insert(:arbor_memory_graphs, {agent_id, graph})

    on_exit(fn ->
      Proposal.delete_all(agent_id)
      :ets.delete(:arbor_memory_graphs, agent_id)
    end)

    {:ok, agent_id: agent_id}
  end

  defp ensure_ets_tables do
    if :ets.whereis(:arbor_memory_graphs) == :undefined do
      :ets.new(:arbor_memory_graphs, [:named_table, :public, :set])
    end

    if :ets.whereis(:arbor_memory_proposals) == :undefined do
      :ets.new(:arbor_memory_proposals, [:named_table, :public, :set])
    end
  end

  describe "Phase 3 proposal types" do
    test "creates :goal proposal", %{agent_id: agent_id} do
      {:ok, p} =
        Proposal.create(agent_id, :goal, %{
          content: "Learn Elixir macros",
          metadata: %{goal_data: %{"type" => "achieve"}}
        })

      assert p.type == :goal
      assert p.content == "Learn Elixir macros"
    end

    test "creates :goal_update proposal", %{agent_id: agent_id} do
      {:ok, p} =
        Proposal.create(agent_id, :goal_update, %{
          content: "Update goal progress to 50%",
          metadata: %{update_data: %{"id" => "g1", "progress" => 0.5}}
        })

      assert p.type == :goal_update
    end

    test "creates :thought proposal", %{agent_id: agent_id} do
      {:ok, p} =
        Proposal.create(agent_id, :thought, %{content: "Interesting pattern detected"})

      assert p.type == :thought
    end

    test "creates :concern proposal", %{agent_id: agent_id} do
      {:ok, p} =
        Proposal.create(agent_id, :concern, %{content: "Memory growing unbounded"})

      assert p.type == :concern
    end

    test "creates :curiosity proposal", %{agent_id: agent_id} do
      {:ok, p} =
        Proposal.create(agent_id, :curiosity, %{content: "What does this function do?"})

      assert p.type == :curiosity
    end

    test "creates :identity proposal", %{agent_id: agent_id} do
      {:ok, p} =
        Proposal.create(agent_id, :identity, %{
          content: "I tend to be thorough in explanations",
          source: "heartbeat"
        })

      assert p.type == :identity
    end

    test "creates :intent proposal", %{agent_id: agent_id} do
      {:ok, p} =
        Proposal.create(agent_id, :intent, %{
          content: "Execute file search",
          metadata: %{decomposition: %{"capability" => "read", "op" => "file"}}
        })

      assert p.type == :intent
    end

    test "creates :cognitive_mode proposal", %{agent_id: agent_id} do
      {:ok, p} =
        Proposal.create(agent_id, :cognitive_mode, %{
          content: "Switch to goal_pursuit mode",
          metadata: %{from: "reflection", to: "goal_pursuit"}
        })

      assert p.type == :cognitive_mode
    end
  end

  describe "dedup across new types" do
    test "deduplicates :thought proposals with similar content", %{agent_id: agent_id} do
      {:ok, p1} =
        Proposal.create(agent_id, :thought, %{
          content: "This is a recurring observation about the system behavior and architecture"
        })

      {:ok, p2} =
        Proposal.create(agent_id, :thought, %{
          content: "This is a recurring observation about the system behavior and architecture"
        })

      # Should be deduped (exact match)
      assert p1.id == p2.id
    end

    test "different types are not deduped against each other", %{agent_id: agent_id} do
      {:ok, p1} = Proposal.create(agent_id, :thought, %{content: "Observation A"})
      {:ok, p2} = Proposal.create(agent_id, :concern, %{content: "Observation A"})

      # Different types → different proposals
      assert p1.id != p2.id
    end
  end

  describe "node type mapping for new types" do
    test ":thought accepts to :observation node", %{agent_id: agent_id} do
      {:ok, p} = Proposal.create(agent_id, :thought, %{content: "Test thought"})
      {:ok, node_id} = Proposal.accept(agent_id, p.id)

      [{^agent_id, graph}] = :ets.lookup(:arbor_memory_graphs, agent_id)
      {:ok, node} = KnowledgeGraph.get_node(graph, node_id)
      assert node.type == :observation
    end

    test ":concern accepts to :observation node", %{agent_id: agent_id} do
      {:ok, p} = Proposal.create(agent_id, :concern, %{content: "Test concern"})
      {:ok, node_id} = Proposal.accept(agent_id, p.id)

      [{^agent_id, graph}] = :ets.lookup(:arbor_memory_graphs, agent_id)
      {:ok, node} = KnowledgeGraph.get_node(graph, node_id)
      assert node.type == :observation
    end

    test ":curiosity accepts to :observation node", %{agent_id: agent_id} do
      {:ok, p} = Proposal.create(agent_id, :curiosity, %{content: "Test curiosity"})
      {:ok, node_id} = Proposal.accept(agent_id, p.id)

      [{^agent_id, graph}] = :ets.lookup(:arbor_memory_graphs, agent_id)
      {:ok, node} = KnowledgeGraph.get_node(graph, node_id)
      assert node.type == :observation
    end

    test ":cognitive_mode accepts to :observation node", %{agent_id: agent_id} do
      {:ok, p} =
        Proposal.create(agent_id, :cognitive_mode, %{
          content: "Switch to goal_pursuit"
        })

      {:ok, node_id} = Proposal.accept(agent_id, p.id)

      [{^agent_id, graph}] = :ets.lookup(:arbor_memory_graphs, agent_id)
      {:ok, node} = KnowledgeGraph.get_node(graph, node_id)
      assert node.type == :observation
    end

    test ":identity accepts to :trait node with domain routing", %{agent_id: agent_id} do
      {:ok, p} = Proposal.create(agent_id, :identity, %{content: "Identity trait"})
      {:ok, node_id} = Proposal.accept(agent_id, p.id)

      [{^agent_id, graph}] = :ets.lookup(:arbor_memory_graphs, agent_id)
      {:ok, node} = KnowledgeGraph.get_node(graph, node_id)
      assert node.type == :trait
      assert node.metadata.reference_only == true
      assert node.metadata.domain_store == "self_knowledge"
    end

    test ":goal accepts to :goal node with domain routing", %{agent_id: agent_id} do
      {:ok, p} = Proposal.create(agent_id, :goal, %{content: "New goal"})
      {:ok, node_id} = Proposal.accept(agent_id, p.id)

      [{^agent_id, graph}] = :ets.lookup(:arbor_memory_graphs, agent_id)
      {:ok, node} = KnowledgeGraph.get_node(graph, node_id)
      assert node.type == :goal
      assert node.metadata.reference_only == true
      assert node.metadata.domain_store == "goals"
      assert is_binary(node.metadata.domain_key)
    end

    test ":goal_update accepts to :goal node with domain routing", %{agent_id: agent_id} do
      {:ok, p} =
        Proposal.create(agent_id, :goal_update, %{
          content: "Updated progress",
          metadata: %{update_data: %{"id" => "g1", "progress" => 0.5}}
        })

      {:ok, node_id} = Proposal.accept(agent_id, p.id)

      [{^agent_id, graph}] = :ets.lookup(:arbor_memory_graphs, agent_id)
      {:ok, node} = KnowledgeGraph.get_node(graph, node_id)
      assert node.type == :goal
      assert node.metadata.reference_only == true
      assert node.metadata.domain_store == "goals"
    end

    test ":intent accepts to :intention node with domain routing", %{agent_id: agent_id} do
      {:ok, p} =
        Proposal.create(agent_id, :intent, %{
          content: "Decomposed intent",
          metadata: %{decomposition: %{"capability" => "read", "op" => "file"}}
        })

      {:ok, node_id} = Proposal.accept(agent_id, p.id)

      [{^agent_id, graph}] = :ets.lookup(:arbor_memory_graphs, agent_id)
      {:ok, node} = KnowledgeGraph.get_node(graph, node_id)
      assert node.type == :intention
      assert node.metadata.reference_only == true
      assert node.metadata.domain_store == "intents"
    end
  end

  describe "domain-store routing" do
    test "KG-only types create direct nodes without domain routing", %{agent_id: agent_id} do
      {:ok, p} = Proposal.create(agent_id, :thought, %{content: "Direct observation"})
      {:ok, node_id} = Proposal.accept(agent_id, p.id)

      [{^agent_id, graph}] = :ets.lookup(:arbor_memory_graphs, agent_id)
      {:ok, node} = KnowledgeGraph.get_node(graph, node_id)

      # KG-only types have full content and no domain routing metadata
      assert node.content == "Direct observation"
      refute Map.has_key?(node.metadata, :reference_only)
      refute Map.has_key?(node.metadata, :domain_store)
    end

    test "domain-routed types truncate content in KG reference", %{agent_id: agent_id} do
      long_content = String.duplicate("x", 300)

      {:ok, p} =
        Proposal.create(agent_id, :identity, %{content: long_content})

      {:ok, node_id} = Proposal.accept(agent_id, p.id)

      [{^agent_id, graph}] = :ets.lookup(:arbor_memory_graphs, agent_id)
      {:ok, node} = KnowledgeGraph.get_node(graph, node_id)

      assert String.length(node.content) <= 203
      assert String.ends_with?(node.content, "...")
    end

    test "original proposal types still work as KG-only", %{agent_id: agent_id} do
      {:ok, p} = Proposal.create(agent_id, :fact, %{content: "A fact"})
      {:ok, node_id} = Proposal.accept(agent_id, p.id)

      [{^agent_id, graph}] = :ets.lookup(:arbor_memory_graphs, agent_id)
      {:ok, node} = KnowledgeGraph.get_node(graph, node_id)
      assert node.type == :fact
      assert node.content == "A fact"
      refute Map.has_key?(node.metadata, :reference_only)
    end
  end

  describe "stats include new types" do
    test "by_type tracks Phase 3 types", %{agent_id: agent_id} do
      {:ok, _} = Proposal.create(agent_id, :thought, %{content: "T1"})
      {:ok, _} = Proposal.create(agent_id, :concern, %{content: "C1"})
      {:ok, _} = Proposal.create(agent_id, :goal, %{content: "G1"})

      stats = Proposal.stats(agent_id)
      assert stats.by_type[:thought] == 1
      assert stats.by_type[:concern] == 1
      assert stats.by_type[:goal] == 1
      assert stats.pending == 3
    end
  end
end
