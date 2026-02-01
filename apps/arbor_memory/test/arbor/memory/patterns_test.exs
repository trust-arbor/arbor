defmodule Arbor.Memory.PatternsTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.{KnowledgeGraph, Patterns}

  @moduletag :fast

  setup do
    # Ensure ETS table exists
    if :ets.whereis(:arbor_memory_graphs) == :undefined do
      :ets.new(:arbor_memory_graphs, [:named_table, :public, :set])
    end

    agent_id = "test_agent_#{System.unique_integer([:positive])}"

    on_exit(fn ->
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

  describe "analyze/1" do
    test "returns comprehensive analysis", %{agent_id: agent_id} do
      create_graph_with_nodes(agent_id, [
        %{type: :fact, content: "Fact 1", relevance: 0.8},
        %{type: :fact, content: "Fact 2", relevance: 0.5},
        %{type: :skill, content: "Skill 1", relevance: 0.7}
      ])

      analysis = Patterns.analyze(agent_id)

      assert Map.has_key?(analysis, :type_distribution)
      assert Map.has_key?(analysis, :access_concentration)
      assert Map.has_key?(analysis, :decay_risk)
      assert Map.has_key?(analysis, :unused_pins)
      assert Map.has_key?(analysis, :suggestions)
    end

    test "returns error for non-existent agent", %{agent_id: _agent_id} do
      result = Patterns.analyze("nonexistent_agent")
      assert result == {:error, :graph_not_initialized}
    end
  end

  describe "type_distribution/1" do
    test "calculates counts and percentages", %{agent_id: agent_id} do
      create_graph_with_nodes(agent_id, [
        %{type: :fact, content: "F1"},
        %{type: :fact, content: "F2"},
        %{type: :fact, content: "F3"},
        %{type: :skill, content: "S1"}
      ])

      dist = Patterns.type_distribution(agent_id)

      assert dist.total == 4
      assert dist.counts[:fact] == 3
      assert dist.counts[:skill] == 1
      assert dist.percentages[:fact] == 0.75
      assert dist.percentages[:skill] == 0.25
    end

    test "calculates imbalance score", %{agent_id: agent_id} do
      # Very imbalanced: all facts
      create_graph_with_nodes(agent_id, [
        %{type: :fact, content: "F1"},
        %{type: :fact, content: "F2"},
        %{type: :fact, content: "F3"}
      ])

      dist = Patterns.type_distribution(agent_id)

      # Single type = no imbalance (0.0)
      assert dist.imbalance_score == 0.0
    end

    test "handles empty graph", %{agent_id: agent_id} do
      create_graph_with_nodes(agent_id, [])

      dist = Patterns.type_distribution(agent_id)

      assert dist.total == 0
      assert dist.counts == %{}
    end
  end

  describe "access_concentration/1" do
    test "returns 0 for equal access", %{agent_id: agent_id} do
      # All nodes have same access count (0)
      create_graph_with_nodes(agent_id, [
        %{type: :fact, content: "F1"},
        %{type: :fact, content: "F2"},
        %{type: :fact, content: "F3"}
      ])

      gini = Patterns.access_concentration(agent_id)
      assert gini == 0.0
    end
  end

  describe "calculate_gini/1" do
    test "returns 0 for equal distribution" do
      assert Patterns.calculate_gini([10, 10, 10, 10]) == 0.0
    end

    test "returns 0 for empty list" do
      assert Patterns.calculate_gini([]) == 0.0
    end

    test "returns 0 for single element" do
      assert Patterns.calculate_gini([100]) == 0.0
    end

    test "returns high value for unequal distribution" do
      # One element has all the value
      gini = Patterns.calculate_gini([0, 0, 0, 100])
      assert gini > 0.7
    end

    test "returns moderate value for moderate inequality" do
      gini = Patterns.calculate_gini([10, 20, 30, 40])
      assert gini > 0.1 and gini < 0.5
    end
  end

  describe "decay_risk/1" do
    test "identifies at-risk nodes", %{agent_id: agent_id} do
      create_graph_with_nodes(agent_id, [
        %{type: :fact, content: "High", relevance: 0.8},
        %{type: :fact, content: "Low", relevance: 0.15},
        %{type: :fact, content: "Very low", relevance: 0.12}
      ])

      risk = Patterns.decay_risk(agent_id, threshold: 0.25)

      # Two nodes below 0.25 but above prune threshold (0.1)
      assert risk.at_risk_count == 2
      assert risk.at_risk_percentage > 0.5
    end

    test "returns empty when all nodes healthy", %{agent_id: agent_id} do
      create_graph_with_nodes(agent_id, [
        %{type: :fact, content: "High", relevance: 0.8},
        %{type: :fact, content: "Also high", relevance: 0.9}
      ])

      risk = Patterns.decay_risk(agent_id, threshold: 0.25)

      assert risk.at_risk_count == 0
    end
  end

  describe "unused_pins/1" do
    test "identifies unused pinned nodes", %{agent_id: agent_id} do
      # Create graph with pinned node
      graph = KnowledgeGraph.new(agent_id)

      # Add pinned node with old access time
      {:ok, graph, _id} =
        KnowledgeGraph.add_node(graph, %{
          type: :fact,
          content: "Pinned but unused",
          pinned: true
        })

      # Manipulate last_accessed to be old
      [{node_id, node}] = Enum.take(graph.nodes, 1)
      old_time = DateTime.add(DateTime.utc_now(), -14, :day)
      updated_node = %{node | last_accessed: old_time, access_count: 1}
      graph = %{graph | nodes: Map.put(graph.nodes, node_id, updated_node)}

      :ets.insert(:arbor_memory_graphs, {agent_id, graph})

      pins = Patterns.unused_pins(agent_id, access_threshold: 3, days_threshold: 7)

      assert length(pins) == 1
      assert hd(pins).days_stale >= 14
    end

    test "excludes frequently accessed pins", %{agent_id: agent_id} do
      graph = KnowledgeGraph.new(agent_id)

      {:ok, graph, node_id} =
        KnowledgeGraph.add_node(graph, %{
          type: :fact,
          content: "Actively used pin",
          pinned: true
        })

      # Simulate high access count
      node = Map.get(graph.nodes, node_id)
      updated_node = %{node | access_count: 10}
      graph = %{graph | nodes: Map.put(graph.nodes, node_id, updated_node)}

      :ets.insert(:arbor_memory_graphs, {agent_id, graph})

      pins = Patterns.unused_pins(agent_id, access_threshold: 3)

      assert pins == []
    end
  end

  describe "suggestions generation" do
    test "suggests when type distribution is imbalanced", %{agent_id: agent_id} do
      # Create heavily imbalanced graph
      nodes =
        for i <- 1..15 do
          %{type: :fact, content: "Fact #{i}"}
        end ++
          [%{type: :skill, content: "Skill 1"}]

      create_graph_with_nodes(agent_id, nodes)

      analysis = Patterns.analyze(agent_id)

      assert Enum.any?(analysis.suggestions, fn s ->
               String.contains?(s, "weighted toward")
             end)
    end
  end
end
