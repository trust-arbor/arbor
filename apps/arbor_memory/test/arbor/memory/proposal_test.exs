defmodule Arbor.Memory.ProposalTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.{KnowledgeGraph, Proposal}

  @moduletag :fast

  setup do
    # Ensure ETS tables exist
    ensure_ets_tables()

    # Create a unique agent ID for each test
    agent_id = "test_agent_#{System.unique_integer([:positive])}"

    # Initialize a graph for this agent
    graph = KnowledgeGraph.new(agent_id)
    :ets.insert(:arbor_memory_graphs, {agent_id, graph})

    on_exit(fn ->
      # Clean up
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

  describe "create/3" do
    test "creates a fact proposal", %{agent_id: agent_id} do
      {:ok, proposal} =
        Proposal.create(agent_id, :fact, %{
          content: "User prefers dark mode",
          confidence: 0.8
        })

      assert proposal.id =~ ~r/^prop_[a-f0-9]+$/
      assert proposal.agent_id == agent_id
      assert proposal.type == :fact
      assert proposal.content == "User prefers dark mode"
      assert proposal.confidence == 0.8
      assert proposal.status == :pending
    end

    test "creates an insight proposal", %{agent_id: agent_id} do
      {:ok, proposal} =
        Proposal.create(agent_id, :insight, %{
          content: "You tend to be thorough in explanations",
          confidence: 0.7,
          source: "insight_detector"
        })

      assert proposal.type == :insight
      assert proposal.source == "insight_detector"
    end

    test "creates a learning proposal", %{agent_id: agent_id} do
      {:ok, proposal} =
        Proposal.create(agent_id, :learning, %{
          content: "Workflow pattern: Read → Edit",
          confidence: 0.6,
          evidence: ["Observed 5 times"]
        })

      assert proposal.type == :learning
      assert proposal.evidence == ["Observed 5 times"]
    end

    test "creates a pattern proposal", %{agent_id: agent_id} do
      {:ok, proposal} =
        Proposal.create(agent_id, :pattern, %{
          content: "Frequently uses Read before Edit",
          confidence: 0.75
        })

      assert proposal.type == :pattern
    end

    test "rejects invalid type", %{agent_id: agent_id} do
      {:error, {:invalid_type, :invalid, _}} =
        Proposal.create(agent_id, :invalid, %{content: "test"})
    end

    test "requires content", %{agent_id: agent_id} do
      {:error, :missing_content} = Proposal.create(agent_id, :fact, %{})
    end

    test "uses default confidence", %{agent_id: agent_id} do
      {:ok, proposal} = Proposal.create(agent_id, :fact, %{content: "test"})
      assert proposal.confidence == 0.5
    end
  end

  describe "list_pending/2" do
    test "lists all pending proposals", %{agent_id: agent_id} do
      {:ok, _} = Proposal.create(agent_id, :fact, %{content: "Fact 1"})
      {:ok, _} = Proposal.create(agent_id, :insight, %{content: "Insight 1"})

      {:ok, proposals} = Proposal.list_pending(agent_id)
      assert length(proposals) == 2
    end

    test "filters by type", %{agent_id: agent_id} do
      {:ok, _} = Proposal.create(agent_id, :fact, %{content: "Fact 1"})
      {:ok, _} = Proposal.create(agent_id, :insight, %{content: "Insight 1"})

      {:ok, facts} = Proposal.list_pending(agent_id, type: :fact)
      assert length(facts) == 1
      assert hd(facts).type == :fact
    end

    test "limits results", %{agent_id: agent_id} do
      for i <- 1..5 do
        {:ok, _} = Proposal.create(agent_id, :fact, %{content: "Fact #{i}"})
      end

      {:ok, proposals} = Proposal.list_pending(agent_id, limit: 3)
      assert length(proposals) == 3
    end

    test "sorts by created_at by default", %{agent_id: agent_id} do
      {:ok, p1} = Proposal.create(agent_id, :fact, %{content: "First"})
      Process.sleep(1)
      {:ok, p2} = Proposal.create(agent_id, :fact, %{content: "Second"})

      {:ok, proposals} = Proposal.list_pending(agent_id)
      # Default sort is descending by created_at
      assert hd(proposals).id == p2.id
    end

    test "sorts by confidence", %{agent_id: agent_id} do
      {:ok, _} = Proposal.create(agent_id, :fact, %{content: "Low", confidence: 0.3})
      {:ok, _} = Proposal.create(agent_id, :fact, %{content: "High", confidence: 0.9})

      {:ok, proposals} = Proposal.list_pending(agent_id, sort_by: :confidence)
      assert hd(proposals).confidence == 0.9
    end
  end

  describe "get/2" do
    test "retrieves a proposal by ID", %{agent_id: agent_id} do
      {:ok, created} = Proposal.create(agent_id, :fact, %{content: "Test"})

      {:ok, retrieved} = Proposal.get(agent_id, created.id)
      assert retrieved.id == created.id
      assert retrieved.content == "Test"
    end

    test "returns error for non-existent proposal", %{agent_id: agent_id} do
      {:error, :not_found} = Proposal.get(agent_id, "prop_nonexistent")
    end
  end

  describe "accept/2" do
    test "accepts a proposal and adds to knowledge graph", %{agent_id: agent_id} do
      {:ok, proposal} =
        Proposal.create(agent_id, :fact, %{
          content: "Important fact",
          confidence: 0.7
        })

      {:ok, node_id} = Proposal.accept(agent_id, proposal.id)

      assert node_id =~ ~r/^node_/

      # Verify node was added to graph
      [{^agent_id, graph}] = :ets.lookup(:arbor_memory_graphs, agent_id)
      {:ok, node} = KnowledgeGraph.get_node(graph, node_id)

      assert node.content == "Important fact"
      # Confidence boost of 0.2 (0.7 + 0.2 = 0.9)
      assert_in_delta node.relevance, 0.9, 0.001
    end

    test "marks proposal as accepted", %{agent_id: agent_id} do
      {:ok, proposal} = Proposal.create(agent_id, :fact, %{content: "Test"})
      {:ok, _} = Proposal.accept(agent_id, proposal.id)

      {:ok, updated} = Proposal.get(agent_id, proposal.id)
      assert updated.status == :accepted
    end

    test "converts proposal types to node types correctly", %{agent_id: agent_id} do
      # fact -> :fact
      {:ok, p1} = Proposal.create(agent_id, :fact, %{content: "F"})
      {:ok, n1_id} = Proposal.accept(agent_id, p1.id)

      # insight -> :insight
      {:ok, p2} = Proposal.create(agent_id, :insight, %{content: "I"})
      {:ok, n2_id} = Proposal.accept(agent_id, p2.id)

      # learning -> :skill
      {:ok, p3} = Proposal.create(agent_id, :learning, %{content: "L"})
      {:ok, n3_id} = Proposal.accept(agent_id, p3.id)

      # pattern -> :experience
      {:ok, p4} = Proposal.create(agent_id, :pattern, %{content: "P"})
      {:ok, n4_id} = Proposal.accept(agent_id, p4.id)

      [{^agent_id, graph}] = :ets.lookup(:arbor_memory_graphs, agent_id)
      {:ok, n1} = KnowledgeGraph.get_node(graph, n1_id)
      {:ok, n2} = KnowledgeGraph.get_node(graph, n2_id)
      {:ok, n3} = KnowledgeGraph.get_node(graph, n3_id)
      {:ok, n4} = KnowledgeGraph.get_node(graph, n4_id)

      assert n1.type == :fact
      assert n2.type == :insight
      assert n3.type == :skill
      assert n4.type == :experience
    end
  end

  describe "reject/3" do
    test "rejects a proposal", %{agent_id: agent_id} do
      {:ok, proposal} = Proposal.create(agent_id, :fact, %{content: "Test"})

      :ok = Proposal.reject(agent_id, proposal.id)

      {:ok, updated} = Proposal.get(agent_id, proposal.id)
      assert updated.status == :rejected
    end

    test "stores rejection reason", %{agent_id: agent_id} do
      {:ok, proposal} = Proposal.create(agent_id, :fact, %{content: "Test"})

      :ok = Proposal.reject(agent_id, proposal.id, reason: "Not accurate")

      {:ok, updated} = Proposal.get(agent_id, proposal.id)
      assert updated.metadata[:rejection_reason] == "Not accurate"
    end
  end

  describe "defer/2" do
    test "defers a proposal", %{agent_id: agent_id} do
      {:ok, proposal} = Proposal.create(agent_id, :fact, %{content: "Test"})

      :ok = Proposal.defer(agent_id, proposal.id)

      {:ok, updated} = Proposal.get(agent_id, proposal.id)
      assert updated.status == :deferred
      assert updated.metadata[:deferred_count] == 1
    end

    test "tracks multiple deferrals", %{agent_id: agent_id} do
      {:ok, proposal} = Proposal.create(agent_id, :fact, %{content: "Test"})

      :ok = Proposal.defer(agent_id, proposal.id)
      :ok = Proposal.undefer(agent_id, proposal.id)
      :ok = Proposal.defer(agent_id, proposal.id)

      {:ok, updated} = Proposal.get(agent_id, proposal.id)
      assert updated.metadata[:deferred_count] == 2
    end
  end

  describe "accept_all/2" do
    test "accepts all pending proposals", %{agent_id: agent_id} do
      {:ok, p1} = Proposal.create(agent_id, :fact, %{content: "Fact 1"})
      {:ok, p2} = Proposal.create(agent_id, :fact, %{content: "Fact 2"})

      {:ok, results} = Proposal.accept_all(agent_id)

      assert length(results) == 2
      proposal_ids = Enum.map(results, fn {prop_id, _node_id} -> prop_id end)
      assert p1.id in proposal_ids
      assert p2.id in proposal_ids
    end

    test "accepts only proposals of specified type", %{agent_id: agent_id} do
      {:ok, _} = Proposal.create(agent_id, :fact, %{content: "Fact 1"})
      {:ok, _} = Proposal.create(agent_id, :insight, %{content: "Insight 1"})

      {:ok, results} = Proposal.accept_all(agent_id, :fact)

      assert length(results) == 1

      # Check that insight is still pending
      {:ok, pending} = Proposal.list_pending(agent_id)
      assert length(pending) == 1
      assert hd(pending).type == :insight
    end
  end

  describe "count_pending/2" do
    test "counts pending proposals", %{agent_id: agent_id} do
      assert Proposal.count_pending(agent_id) == 0

      {:ok, _} = Proposal.create(agent_id, :fact, %{content: "Fact 1"})
      {:ok, _} = Proposal.create(agent_id, :fact, %{content: "Fact 2"})

      assert Proposal.count_pending(agent_id) == 2
    end

    test "filters by type", %{agent_id: agent_id} do
      {:ok, _} = Proposal.create(agent_id, :fact, %{content: "Fact 1"})
      {:ok, _} = Proposal.create(agent_id, :insight, %{content: "Insight 1"})

      assert Proposal.count_pending(agent_id, type: :fact) == 1
    end
  end

  describe "stats/1" do
    test "returns proposal statistics", %{agent_id: agent_id} do
      {:ok, _} = Proposal.create(agent_id, :fact, %{content: "F1", confidence: 0.8})
      {:ok, p2} = Proposal.create(agent_id, :fact, %{content: "F2", confidence: 0.6})
      {:ok, p3} = Proposal.create(agent_id, :insight, %{content: "I1", confidence: 0.7})

      :ok = Proposal.reject(agent_id, p2.id)
      {:ok, _} = Proposal.accept(agent_id, p3.id)

      stats = Proposal.stats(agent_id)

      assert stats.total == 3
      assert stats.pending == 1
      assert stats.accepted == 1
      assert stats.rejected == 1
      assert stats.by_type[:fact] == 2
      assert stats.by_type[:insight] == 1
    end
  end

  describe "status validation" do
    test "cannot accept already accepted proposal", %{agent_id: agent_id} do
      {:ok, proposal} = Proposal.create(agent_id, :fact, %{content: "Test"})
      {:ok, _} = Proposal.accept(agent_id, proposal.id)

      {:error, {:invalid_status, :accepted, :pending}} =
        Proposal.accept(agent_id, proposal.id)
    end

    test "cannot reject already rejected proposal", %{agent_id: agent_id} do
      {:ok, proposal} = Proposal.create(agent_id, :fact, %{content: "Test"})
      :ok = Proposal.reject(agent_id, proposal.id)

      {:error, {:invalid_status, :rejected, :pending}} =
        Proposal.reject(agent_id, proposal.id)
    end
  end
end
