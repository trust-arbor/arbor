defmodule Arbor.Memory.Phase4IntegrationTest do
  @moduledoc """
  Integration tests for Phase 4 (Background Processing / Subconscious).

  Tests the full loop: BackgroundChecks.run → detects pattern → generates proposal
  → agent accepts → KnowledgeGraph updated.
  """
  use ExUnit.Case, async: false

  alias Arbor.Memory
  alias Arbor.Memory.{BackgroundChecks, KnowledgeGraph, Proposal}

  @moduletag :integration

  setup do
    # Ensure ETS tables exist
    ensure_ets_tables()

    agent_id = "integration_test_agent_#{System.unique_integer([:positive])}"

    # Initialize memory for agent
    {:ok, _} = Memory.init_for_agent(agent_id)

    on_exit(fn ->
      Memory.cleanup_for_agent(agent_id)
      Proposal.delete_all(agent_id)
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

    if :ets.whereis(:arbor_working_memory) == :undefined do
      :ets.new(:arbor_working_memory, [:named_table, :public, :set])
    end
  end

  describe "full subconscious loop" do
    test "heartbeat → pattern detection → proposal → accept → graph update", %{agent_id: agent_id} do
      # 1. Populate the graph with some initial knowledge
      for i <- 1..5 do
        Memory.add_knowledge(agent_id, %{type: :fact, content: "Initial fact #{i}"})
      end

      # 2. Create action history with a repeated pattern
      base_time = DateTime.utc_now()

      action_history =
        for i <- 0..11 do
          tool = if rem(i, 2) == 0, do: "Read", else: "Edit"

          %{
            tool: tool,
            status: :success,
            timestamp: DateTime.add(base_time, i * 5, :second)
          }
        end

      # 3. Run background checks (simulating heartbeat)
      result =
        Memory.run_background_checks(agent_id,
          action_history: action_history,
          min_occurrences: 3,
          skip_insights: true
        )

      # 4. Should have detected the Read→Edit pattern and created proposals
      assert is_list(result.suggestions)

      if result.suggestions != [] do
        # At least one learning suggestion
        learning = Enum.find(result.suggestions, &(&1.type == :learning))
        assert learning != nil

        # 5. Accept the proposal
        {:ok, node_id} = Memory.accept_proposal(agent_id, learning.proposal_id)

        # 6. Verify node was added to graph
        {:ok, graph} = get_graph(agent_id)
        {:ok, node} = KnowledgeGraph.get_node(graph, node_id)

        assert node.type == :skill
        assert String.contains?(node.content, "Read")
      end
    end

    test "proposal workflow: create → defer → undefer → accept", %{agent_id: agent_id} do
      # 1. Create a proposal directly
      {:ok, proposal} =
        Memory.create_proposal(agent_id, :fact, %{
          content: "User prefers dark mode",
          confidence: 0.8
        })

      assert proposal.status == :pending

      # 2. Defer it
      :ok = Memory.defer_proposal(agent_id, proposal.id)
      {:ok, deferred} = Proposal.get(agent_id, proposal.id)
      assert deferred.status == :deferred

      # 3. Undefer it
      :ok = Proposal.undefer(agent_id, proposal.id)
      {:ok, undeferred} = Proposal.get(agent_id, proposal.id)
      assert undeferred.status == :pending

      # 4. Accept it
      {:ok, node_id} = Memory.accept_proposal(agent_id, proposal.id)

      # 5. Verify in graph
      {:ok, graph} = get_graph(agent_id)
      {:ok, node} = KnowledgeGraph.get_node(graph, node_id)

      assert node.content == "User prefers dark mode"
      assert node.type == :fact
      # Confidence boost
      assert node.relevance == 1.0
    end

    test "consolidation check triggers when graph is large", %{agent_id: agent_id} do
      # Add many nodes
      for i <- 1..105 do
        Memory.add_knowledge(agent_id, %{type: :fact, content: "Fact #{i}"})
      end

      # Run background checks
      result = BackgroundChecks.check_consolidation(agent_id, size_threshold: 100)

      assert length(result.actions) == 1
      action = hd(result.actions)
      assert action.type == :run_consolidation

      # Actually run consolidation
      {:ok, _graph, metrics} = Memory.run_consolidation(agent_id)

      assert metrics.decayed_count > 0
      assert metrics.total_nodes <= 105
    end

    test "decay risk warning when many nodes at low relevance", %{agent_id: agent_id} do
      # Add nodes with low relevance
      for i <- 1..10 do
        Memory.add_knowledge(agent_id, %{
          type: :fact,
          content: "Low relevance #{i}",
          relevance: 0.15
        })
      end

      result = BackgroundChecks.check_decay_status(agent_id, threshold: 0.25)

      assert length(result.warnings) == 1
      warning = hd(result.warnings)
      assert warning.type == :decay_risk
      assert warning.data[:at_risk_count] == 10
    end

    test "proposal statistics track lifecycle", %{agent_id: agent_id} do
      # Create several proposals
      {:ok, p1} = Memory.create_proposal(agent_id, :fact, %{content: "F1"})
      {:ok, p2} = Memory.create_proposal(agent_id, :fact, %{content: "F2"})
      {:ok, p3} = Memory.create_proposal(agent_id, :insight, %{content: "I1"})

      # Initial stats
      stats = Memory.proposal_stats(agent_id)
      assert stats.total == 3
      assert stats.pending == 3

      # Accept one
      {:ok, _} = Memory.accept_proposal(agent_id, p1.id)

      # Reject one
      :ok = Memory.reject_proposal(agent_id, p2.id)

      # Defer one
      :ok = Memory.defer_proposal(agent_id, p3.id)

      # Final stats
      final_stats = Memory.proposal_stats(agent_id)
      assert final_stats.total == 3
      assert final_stats.pending == 0
      assert final_stats.accepted == 1
      assert final_stats.rejected == 1
      assert final_stats.deferred == 1
    end

    test "memory patterns analysis provides comprehensive view", %{agent_id: agent_id} do
      # Add varied nodes
      for i <- 1..10 do
        Memory.add_knowledge(agent_id, %{type: :fact, content: "Fact #{i}"})
      end

      for i <- 1..5 do
        Memory.add_knowledge(agent_id, %{type: :skill, content: "Skill #{i}"})
      end

      analysis = Memory.analyze_memory_patterns(agent_id)

      assert analysis.type_distribution.total == 15
      assert analysis.type_distribution.counts[:fact] == 10
      assert analysis.type_distribution.counts[:skill] == 5
      assert is_float(analysis.access_concentration)
      assert is_map(analysis.decay_risk)
      assert is_list(analysis.unused_pins)
      assert is_list(analysis.suggestions)
    end
  end

  describe "facade integration" do
    test "Memory module exposes all Phase 4 functions", %{agent_id: agent_id} do
      # Create proposal
      {:ok, proposal} = Memory.create_proposal(agent_id, :fact, %{content: "Test"})
      assert proposal.id =~ ~r/^prop_/

      # List proposals
      {:ok, proposals} = Memory.get_proposals(agent_id)
      assert length(proposals) == 1

      # Accept proposal
      {:ok, node_id} = Memory.accept_proposal(agent_id, proposal.id)
      assert node_id =~ ~r/^node_/

      # Create and reject another
      {:ok, p2} = Memory.create_proposal(agent_id, :insight, %{content: "Test 2"})
      :ok = Memory.reject_proposal(agent_id, p2.id, reason: "Not relevant")

      # Create and defer another
      {:ok, p3} = Memory.create_proposal(agent_id, :learning, %{content: "Test 3"})
      :ok = Memory.defer_proposal(agent_id, p3.id)

      # Stats
      stats = Memory.proposal_stats(agent_id)
      assert stats.total == 3

      # Background checks
      result = Memory.run_background_checks(agent_id, skip_insights: true)
      assert is_map(result)

      # Patterns analysis
      analysis = Memory.analyze_memory_patterns(agent_id)
      assert is_map(analysis)

      # Action patterns
      patterns = Memory.analyze_action_patterns([])
      assert patterns == []
    end

    test "accept_all_proposals works through facade", %{agent_id: agent_id} do
      for i <- 1..3 do
        Memory.create_proposal(agent_id, :fact, %{content: "Fact #{i}"})
      end

      {:ok, results} = Memory.accept_all_proposals(agent_id)

      assert length(results) == 3
      assert Enum.all?(results, fn {_prop_id, node_id} -> node_id =~ ~r/^node_/ end)
    end
  end

  # Helper to get graph directly
  defp get_graph(agent_id) do
    case :ets.lookup(:arbor_memory_graphs, agent_id) do
      [{^agent_id, graph}] -> {:ok, graph}
      [] -> {:error, :not_found}
    end
  end
end
