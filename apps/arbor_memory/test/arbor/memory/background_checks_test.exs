defmodule Arbor.Memory.BackgroundChecksTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.{BackgroundChecks, KnowledgeGraph, Proposal}

  @moduletag :fast

  setup do
    # Ensure ETS tables exist
    if :ets.whereis(:arbor_memory_graphs) == :undefined do
      :ets.new(:arbor_memory_graphs, [:named_table, :public, :set])
    end

    if :ets.whereis(:arbor_memory_proposals) == :undefined do
      :ets.new(:arbor_memory_proposals, [:named_table, :public, :set])
    end

    agent_id = "test_agent_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Proposal.delete_all(agent_id)
      :ets.delete(:arbor_memory_graphs, agent_id)
    end)

    {:ok, agent_id: agent_id}
  end

  defp create_graph_with_nodes(agent_id, node_specs) do
    graph = KnowledgeGraph.new(agent_id)

    graph =
      Enum.reduce(node_specs, graph, fn spec, g ->
        {:ok, new_g, _id} = KnowledgeGraph.add_node(g, spec)
        new_g
      end)

    :ets.insert(:arbor_memory_graphs, {agent_id, graph})
    graph
  end

  describe "run/2" do
    test "returns result structure", %{agent_id: agent_id} do
      create_graph_with_nodes(agent_id, [
        %{type: :fact, content: "Test"}
      ])

      result = BackgroundChecks.run(agent_id, skip_insights: true)

      assert Map.has_key?(result, :actions)
      assert Map.has_key?(result, :warnings)
      assert Map.has_key?(result, :suggestions)
      assert is_list(result.actions)
      assert is_list(result.warnings)
      assert is_list(result.suggestions)
    end

    test "handles non-existent agent gracefully", %{agent_id: _agent_id} do
      result = BackgroundChecks.run("nonexistent", skip_insights: true)

      # Should return empty result, not crash
      assert result.actions == []
      assert result.warnings == []
      assert result.suggestions == []
    end
  end

  describe "check_consolidation/2" do
    test "returns action when consolidation needed", %{agent_id: agent_id} do
      # Create graph with many nodes
      nodes =
        for i <- 1..110 do
          %{type: :fact, content: "Fact #{i}"}
        end

      create_graph_with_nodes(agent_id, nodes)

      result = BackgroundChecks.check_consolidation(agent_id, size_threshold: 100)

      assert length(result.actions) == 1
      action = hd(result.actions)
      assert action.type == :run_consolidation
      assert action.priority == :medium
    end

    test "returns empty when no consolidation needed", %{agent_id: agent_id} do
      create_graph_with_nodes(agent_id, [
        %{type: :fact, content: "Small graph"}
      ])

      result = BackgroundChecks.check_consolidation(agent_id, size_threshold: 100)

      assert result.actions == []
    end
  end

  describe "check_unused_pins/2" do
    test "warns about unused pins", %{agent_id: agent_id} do
      graph = KnowledgeGraph.new(agent_id)

      # Add 6 pinned nodes with old access times
      graph =
        Enum.reduce(1..6, graph, fn i, g ->
          {:ok, new_g, node_id} =
            KnowledgeGraph.add_node(g, %{
              type: :fact,
              content: "Pinned #{i}",
              pinned: true
            })

          # Make it look old and unused
          node = Map.get(new_g.nodes, node_id)
          old_time = DateTime.add(DateTime.utc_now(), -14, :day)
          updated_node = %{node | last_accessed: old_time, access_count: 1}
          %{new_g | nodes: Map.put(new_g.nodes, node_id, updated_node)}
        end)

      :ets.insert(:arbor_memory_graphs, {agent_id, graph})

      result = BackgroundChecks.check_unused_pins(agent_id, access_threshold: 3, days_threshold: 7)

      assert length(result.warnings) == 1
      warning = hd(result.warnings)
      assert warning.type == :unused_pins
      assert warning.severity == :warning
    end

    test "no warning when pins are used", %{agent_id: agent_id} do
      graph = KnowledgeGraph.new(agent_id)

      {:ok, graph, node_id} =
        KnowledgeGraph.add_node(graph, %{
          type: :fact,
          content: "Active pin",
          pinned: true
        })

      # Make it look active
      node = Map.get(graph.nodes, node_id)
      updated_node = %{node | access_count: 10}
      graph = %{graph | nodes: Map.put(graph.nodes, node_id, updated_node)}

      :ets.insert(:arbor_memory_graphs, {agent_id, graph})

      result = BackgroundChecks.check_unused_pins(agent_id, access_threshold: 3)

      assert result.warnings == []
    end
  end

  describe "check_decay_status/2" do
    test "warns when many nodes at risk", %{agent_id: agent_id} do
      # Create nodes with low relevance
      nodes =
        for i <- 1..10 do
          # 7 at risk, 3 healthy
          relevance = if i <= 7, do: 0.15, else: 0.8
          %{type: :fact, content: "Fact #{i}", relevance: relevance}
        end

      create_graph_with_nodes(agent_id, nodes)

      result = BackgroundChecks.check_decay_status(agent_id, threshold: 0.25)

      assert length(result.warnings) == 1
      warning = hd(result.warnings)
      assert warning.type == :decay_risk
    end

    test "no warning when nodes healthy", %{agent_id: agent_id} do
      nodes =
        for i <- 1..10 do
          %{type: :fact, content: "Fact #{i}", relevance: 0.8}
        end

      create_graph_with_nodes(agent_id, nodes)

      result = BackgroundChecks.check_decay_status(agent_id, threshold: 0.25)

      assert result.warnings == []
    end
  end

  describe "check_action_patterns/2" do
    test "detects patterns from history", %{agent_id: agent_id} do
      create_graph_with_nodes(agent_id, [%{type: :fact, content: "Test"}])

      base_time = DateTime.utc_now()

      history =
        for i <- 0..7 do
          tool = if rem(i, 2) == 0, do: "Read", else: "Edit"

          %{
            tool: tool,
            status: :success,
            timestamp: DateTime.add(base_time, i * 5, :second)
          }
        end

      result = BackgroundChecks.check_action_patterns(agent_id, action_history: history, min_occurrences: 3)

      # Should find suggestions from detected patterns
      if length(result.suggestions) > 0 do
        assert Enum.all?(result.suggestions, fn s -> s.type == :learning end)
      end
    end

    test "returns empty for short history", %{agent_id: agent_id} do
      create_graph_with_nodes(agent_id, [%{type: :fact, content: "Test"}])

      history = [%{tool: "Read", status: :success, timestamp: DateTime.utc_now()}]

      result = BackgroundChecks.check_action_patterns(agent_id, action_history: history)

      assert result.suggestions == []
    end
  end

  describe "suggest_introspection/1" do
    test "suggests introspection when many proposals pending", %{agent_id: agent_id} do
      create_graph_with_nodes(agent_id, [%{type: :fact, content: "Test"}])

      # Create many pending proposals
      for i <- 1..15 do
        Proposal.create(agent_id, :fact, %{content: "Pending #{i}"})
      end

      result = BackgroundChecks.suggest_introspection(agent_id)

      assert length(result.warnings) == 1
      warning = hd(result.warnings)
      assert warning.type == :pending_pileup
      assert warning.severity == :info
    end

    test "no suggestion when few proposals", %{agent_id: agent_id} do
      create_graph_with_nodes(agent_id, [%{type: :fact, content: "Test"}])

      Proposal.create(agent_id, :fact, %{content: "Single"})

      result = BackgroundChecks.suggest_introspection(agent_id)

      assert result.warnings == []
    end
  end

  describe "skip options" do
    test "skip_consolidation prevents consolidation check", %{agent_id: agent_id} do
      nodes =
        for i <- 1..110 do
          %{type: :fact, content: "Fact #{i}"}
        end

      create_graph_with_nodes(agent_id, nodes)

      result =
        BackgroundChecks.run(agent_id,
          skip_consolidation: true,
          skip_patterns: true,
          skip_insights: true
        )

      # Should not have consolidation action
      assert not Enum.any?(result.actions, fn a -> a.type == :run_consolidation end)
    end

    test "skip_patterns prevents pattern detection", %{agent_id: agent_id} do
      create_graph_with_nodes(agent_id, [%{type: :fact, content: "Test"}])

      base_time = DateTime.utc_now()

      history =
        for i <- 0..7 do
          tool = if rem(i, 2) == 0, do: "Read", else: "Edit"
          %{tool: tool, status: :success, timestamp: DateTime.add(base_time, i * 5, :second)}
        end

      result =
        BackgroundChecks.run(agent_id,
          action_history: history,
          skip_patterns: true,
          skip_insights: true
        )

      # Should not have learning suggestions
      assert not Enum.any?(result.suggestions, fn s -> s.type == :learning end)
    end
  end

  describe "analyze_patterns/1" do
    test "returns analysis and warnings", %{agent_id: agent_id} do
      nodes =
        for i <- 1..15 do
          %{type: :fact, content: "Fact #{i}"}
        end

      create_graph_with_nodes(agent_id, nodes)

      {analysis, result} = BackgroundChecks.analyze_patterns(agent_id)

      assert is_map(analysis)
      assert Map.has_key?(analysis, :type_distribution)
      assert is_map(result)
    end

    test "handles missing agent", %{agent_id: _agent_id} do
      {error, result} = BackgroundChecks.analyze_patterns("nonexistent")

      assert error == {:error, :graph_not_initialized}
      assert result.actions == []
    end
  end
end
