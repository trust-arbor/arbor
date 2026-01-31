defmodule Arbor.Memory.ConsolidationTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.{Consolidation, KnowledgeGraph}

  @moduletag :fast

  # Helper to create a graph with some nodes
  defp graph_with_nodes(agent_id, node_specs) do
    Enum.reduce(node_specs, KnowledgeGraph.new(agent_id), fn spec, graph ->
      node_data =
        case spec do
          {type, content, relevance} ->
            %{type: type, content: content, relevance: relevance}

          {type, content, relevance, opts} ->
            Map.merge(%{type: type, content: content, relevance: relevance}, Map.new(opts))
        end

      {:ok, new_graph, _id} = KnowledgeGraph.add_node(graph, node_data)
      new_graph
    end)
  end

  describe "consolidate/3" do
    test "applies decay to non-pinned nodes" do
      # Use higher initial values so we can clearly see decay
      graph =
        graph_with_nodes("agent_001", [
          {:fact, "Fact 1", 1.0},
          {:fact, "Fact 2", 0.9}
        ])

      # Disable reinforcement to see pure decay effect
      {:ok, new_graph, metrics} =
        Consolidation.consolidate("agent_001", graph,
          archive: false,
          reinforce_window_hours: 0
        )

      # Nodes should have lower relevance after decay (decay rate is 0.10 by default)
      new_nodes = Map.values(new_graph.nodes)
      assert Enum.all?(new_nodes, fn n -> n.relevance <= 0.9 end)
      assert metrics.decayed_count == 2
    end

    test "prunes nodes below threshold after decay" do
      # Node starts at 0.15, decay of 0.10 brings it to 0.05 which is below 0.1 threshold
      graph =
        graph_with_nodes("agent_001", [
          {:fact, "High relevance", 0.8},
          {:fact, "Low relevance", 0.15}
        ])

      {:ok, new_graph, metrics} =
        Consolidation.consolidate("agent_001", graph,
          prune_threshold: 0.1,
          archive: false,
          reinforce_window_hours: 0
        )

      assert metrics.pruned_count == 1
      assert map_size(new_graph.nodes) == 1
    end

    test "does not prune pinned nodes" do
      # Pinned node at 0.15 -> 0.05 after decay, but should NOT be pruned
      # Unpinned at 0.15 -> 0.05 after decay, SHOULD be pruned
      graph =
        graph_with_nodes("agent_001", [
          {:fact, "Pinned low", 0.15, pinned: true},
          {:fact, "Unpinned low", 0.15}
        ])

      {:ok, new_graph, metrics} =
        Consolidation.consolidate("agent_001", graph,
          prune_threshold: 0.1,
          archive: false,
          reinforce_window_hours: 0
        )

      # Only the unpinned node should be pruned
      assert metrics.pruned_count == 1
      assert map_size(new_graph.nodes) == 1

      # Remaining node should be the pinned one
      [remaining] = Map.values(new_graph.nodes)
      assert remaining.pinned == true
    end

    test "reinforces recently-accessed nodes" do
      graph = KnowledgeGraph.new("agent_001")

      # Add a node and reinforce it (to simulate recent access)
      {:ok, graph, node_id} =
        KnowledgeGraph.add_node(graph, %{
          type: :fact,
          content: "Recently accessed",
          relevance: 0.5
        })

      {:ok, graph, _} = KnowledgeGraph.reinforce(graph, node_id)

      {:ok, _new_graph, metrics} =
        Consolidation.consolidate("agent_001", graph,
          reinforce_window_hours: 24,
          reinforce_boost: 0.1,
          archive: false
        )

      # The node should have been reinforced (counteracting decay)
      assert metrics.reinforced_count == 1
    end

    test "returns comprehensive metrics" do
      graph =
        graph_with_nodes("agent_001", [
          {:fact, "Fact 1", 0.8},
          {:fact, "Fact 2", 0.05}
        ])

      {:ok, _new_graph, metrics} =
        Consolidation.consolidate("agent_001", graph,
          prune_threshold: 0.1,
          archive: false
        )

      assert Map.has_key?(metrics, :decayed_count)
      assert Map.has_key?(metrics, :reinforced_count)
      assert Map.has_key?(metrics, :archived_count)
      assert Map.has_key?(metrics, :pruned_count)
      assert Map.has_key?(metrics, :evicted_count)
      assert Map.has_key?(metrics, :duration_ms)
      assert Map.has_key?(metrics, :total_nodes)
      assert Map.has_key?(metrics, :average_relevance)
    end
  end

  describe "should_consolidate?/2" do
    test "returns true when graph exceeds size threshold" do
      # Create graph with many nodes
      nodes =
        for i <- 1..101 do
          {:fact, "Fact #{i}", 0.5}
        end

      graph = graph_with_nodes("agent_001", nodes)

      assert Consolidation.should_consolidate?(graph, size_threshold: 100)
    end

    test "returns false when graph is small" do
      graph =
        graph_with_nodes("agent_001", [
          {:fact, "Fact 1", 0.8}
        ])

      refute Consolidation.should_consolidate?(graph, size_threshold: 100)
    end

    test "returns true when time since last consolidation exceeds interval" do
      graph =
        graph_with_nodes("agent_001", [
          {:fact, "Fact 1", 0.8}
        ])

      # Last consolidation was 2 hours ago
      last = DateTime.add(DateTime.utc_now(), -120, :minute)

      assert Consolidation.should_consolidate?(graph,
               size_threshold: 100,
               min_interval_minutes: 60,
               last_consolidation: last
             )
    end

    test "returns false when last consolidation was recent" do
      graph =
        graph_with_nodes("agent_001", [
          {:fact, "Fact 1", 0.8}
        ])

      # Last consolidation was 30 minutes ago
      last = DateTime.add(DateTime.utc_now(), -30, :minute)

      refute Consolidation.should_consolidate?(graph,
               size_threshold: 100,
               min_interval_minutes: 60,
               last_consolidation: last
             )
    end
  end

  describe "candidates_for_pruning/2" do
    test "returns nodes below threshold" do
      graph =
        graph_with_nodes("agent_001", [
          {:fact, "High", 0.8},
          {:fact, "Medium", 0.15},
          {:fact, "Low", 0.05}
        ])

      candidates = Consolidation.candidates_for_pruning(graph, 0.2)

      assert length(candidates) == 2
      assert Enum.all?(candidates, fn n -> n.relevance < 0.2 end)
    end

    test "excludes pinned nodes" do
      graph =
        graph_with_nodes("agent_001", [
          {:fact, "Pinned low", 0.01, pinned: true},
          {:fact, "Unpinned low", 0.01}
        ])

      candidates = Consolidation.candidates_for_pruning(graph, 0.1)

      assert length(candidates) == 1
      assert hd(candidates).pinned == false
    end

    test "returns nodes sorted by relevance ascending" do
      graph =
        graph_with_nodes("agent_001", [
          {:fact, "Low", 0.01},
          {:fact, "Medium", 0.05},
          {:fact, "High-ish", 0.08}
        ])

      candidates = Consolidation.candidates_for_pruning(graph, 0.1)

      relevances = Enum.map(candidates, & &1.relevance)
      assert relevances == Enum.sort(relevances)
    end
  end

  describe "preview/2" do
    test "shows what consolidation would do" do
      graph =
        graph_with_nodes("agent_001", [
          {:fact, "High", 0.8},
          {:fact, "Low", 0.05}
        ])

      preview = Consolidation.preview(graph, prune_threshold: 0.1)

      assert preview.current_node_count == 2
      assert preview.would_prune_count == 1
      assert is_list(preview.nodes_below_threshold)
      assert is_float(preview.average_relevance_before)
      assert is_float(preview.average_relevance_after_decay)

      # After decay, avg relevance should be lower
      assert preview.average_relevance_after_decay < preview.average_relevance_before
    end

    test "returns empty prune list when all nodes are healthy" do
      graph =
        graph_with_nodes("agent_001", [
          {:fact, "High", 0.8},
          {:fact, "Also high", 0.9}
        ])

      preview = Consolidation.preview(graph, prune_threshold: 0.1)

      assert preview.would_prune_count == 0
      assert preview.nodes_below_threshold == []
    end
  end

  describe "quota enforcement" do
    test "evicts lowest-relevance nodes when over quota" do
      # KnowledgeGraph enforces quota on add_node, so we need a graph that's already
      # over quota. We do this by creating nodes then changing the config.

      # Create graph with high quota first
      graph = KnowledgeGraph.new("agent_001", max_nodes_per_type: 100)

      # Add 3 nodes of the same type
      {:ok, graph, _} =
        KnowledgeGraph.add_node(graph, %{type: :fact, content: "Low", relevance: 0.3})

      {:ok, graph, _} =
        KnowledgeGraph.add_node(graph, %{type: :fact, content: "High", relevance: 0.9})

      {:ok, graph, _} =
        KnowledgeGraph.add_node(graph, %{type: :fact, content: "Medium", relevance: 0.6})

      # Now reduce the quota by updating config
      graph = %{graph | config: Map.put(graph.config, :max_nodes_per_type, 2)}

      {:ok, new_graph, metrics} =
        Consolidation.consolidate("agent_001", graph,
          archive: false,
          reinforce_window_hours: 0
        )

      # Should have evicted 1 node (the lowest relevance one after decay)
      assert metrics.evicted_count == 1
      assert map_size(new_graph.nodes) == 2

      # Remaining nodes should be the higher-relevance ones (after decay)
      # Original 0.3 -> 0.2 after decay, should be evicted
      # Original 0.9 -> 0.8 after decay
      # Original 0.6 -> 0.5 after decay
      remaining_contents =
        new_graph.nodes
        |> Map.values()
        |> Enum.map(& &1.content)
        |> Enum.sort()

      # The lowest (originally "Low") should have been evicted
      assert "Low" not in remaining_contents
    end
  end
end
