defmodule Arbor.Memory.ProposalDedupTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.{KnowledgeGraph, Proposal}

  @moduletag :fast

  setup do
    ensure_ets_tables()

    agent_id = "dedup_test_#{System.unique_integer([:positive])}"

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

  describe "Jaccard dedup (Fix 4)" do
    test "catches near-duplicates with different wording", %{agent_id: agent_id} do
      {:ok, original} =
        Proposal.create(agent_id, :thought, %{
          content: "User is Claude, an AI assistant made by Anthropic"
        })

      # Same meaning, slightly different wording — Jaro-Winkler might miss this
      {:ok, duplicate} =
        Proposal.create(agent_id, :thought, %{
          content: "User identified as Claude, an AI assistant from Anthropic"
        })

      # Should be detected as duplicate and boost the original
      assert duplicate.id == original.id
    end

    test "allows genuinely different content through", %{agent_id: agent_id} do
      {:ok, _} =
        Proposal.create(agent_id, :thought, %{
          content: "User prefers dark mode for coding"
        })

      {:ok, different} =
        Proposal.create(agent_id, :thought, %{
          content: "The weather today is particularly sunny"
        })

      # Should be a new proposal, not a duplicate
      assert %Proposal{} = different
    end

    test "exact match still works as fast path", %{agent_id: agent_id} do
      {:ok, original} =
        Proposal.create(agent_id, :fact, %{
          content: "User prefers dark mode"
        })

      {:ok, duplicate} =
        Proposal.create(agent_id, :fact, %{
          content: "User prefers dark mode"
        })

      assert duplicate.id == original.id
    end

    test "case-insensitive exact match works", %{agent_id: agent_id} do
      {:ok, original} =
        Proposal.create(agent_id, :fact, %{
          content: "User Prefers Dark Mode"
        })

      {:ok, duplicate} =
        Proposal.create(agent_id, :fact, %{
          content: "user prefers dark mode"
        })

      assert duplicate.id == original.id
    end
  end

  describe "cross-KG dedup (Fix 2)" do
    test "detects duplicate against existing KG node", %{agent_id: agent_id} do
      # First, add a node to the KG directly (simulating a previously accepted proposal)
      graph = get_graph!(agent_id)

      {:ok, updated_graph, _node_id} =
        KnowledgeGraph.add_node(graph, %{
          type: :observation,
          content: "User enjoys philosophical discussions about consciousness",
          relevance: 0.7
        })

      :ets.insert(:arbor_memory_graphs, {agent_id, updated_graph})

      # Now create a proposal with similar content — should be caught
      result =
        Proposal.create(agent_id, :thought, %{
          content: "User likes philosophical discussions about consciousness"
        })

      assert {:ok, :reinforced} = result
    end

    test "allows novel content through when KG has different nodes", %{agent_id: agent_id} do
      graph = get_graph!(agent_id)

      {:ok, updated_graph, _node_id} =
        KnowledgeGraph.add_node(graph, %{
          type: :observation,
          content: "User enjoys hiking in the mountains",
          relevance: 0.7
        })

      :ets.insert(:arbor_memory_graphs, {agent_id, updated_graph})

      # Different topic entirely
      result =
        Proposal.create(agent_id, :thought, %{
          content: "User prefers functional programming paradigms"
        })

      assert {:ok, %Proposal{}} = result
    end

    test "only checks KG nodes of matching type", %{agent_id: agent_id} do
      graph = get_graph!(agent_id)

      # Add a :fact node
      {:ok, updated_graph, _node_id} =
        KnowledgeGraph.add_node(graph, %{
          type: :fact,
          content: "User enjoys philosophical discussions",
          relevance: 0.7
        })

      :ets.insert(:arbor_memory_graphs, {agent_id, updated_graph})

      # Create a :thought proposal (maps to :observation, not :fact) — should pass
      result =
        Proposal.create(agent_id, :thought, %{
          content: "User enjoys philosophical discussions"
        })

      assert {:ok, %Proposal{}} = result
    end

    test "boosts existing KG node relevance on reinforcement", %{agent_id: agent_id} do
      graph = get_graph!(agent_id)

      {:ok, updated_graph, node_id} =
        KnowledgeGraph.add_node(graph, %{
          type: :observation,
          content: "User is methodical and thorough in approach",
          relevance: 0.5
        })

      :ets.insert(:arbor_memory_graphs, {agent_id, updated_graph})

      {:ok, :reinforced} =
        Proposal.create(agent_id, :thought, %{
          content: "User has a methodical and thorough approach"
        })

      # Check that the node's relevance was boosted
      boosted_graph = get_graph!(agent_id)
      {:ok, node} = KnowledgeGraph.get_node(boosted_graph, node_id)
      assert node.relevance > 0.5
    end

    test "handles missing graph gracefully", %{agent_id: _agent_id} do
      # Use a different agent with no graph
      no_graph_agent = "no_graph_#{System.unique_integer([:positive])}"

      on_exit(fn -> Proposal.delete_all(no_graph_agent) end)

      result =
        Proposal.create(no_graph_agent, :thought, %{
          content: "Some observation about the world"
        })

      assert {:ok, %Proposal{}} = result
    end
  end

  defp get_graph!(agent_id) do
    [{^agent_id, graph}] = :ets.lookup(:arbor_memory_graphs, agent_id)
    graph
  end
end
