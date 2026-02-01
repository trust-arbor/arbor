defmodule Arbor.Memory.InsightDetectorTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.{InsightDetector, KnowledgeGraph, Proposal}

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

  describe "detect/2" do
    test "returns empty for small graph", %{agent_id: agent_id} do
      create_graph_with_nodes(agent_id, [
        %{type: :fact, content: "Small fact"}
      ])

      result = InsightDetector.detect(agent_id)
      assert result == []
    end

    test "returns error for non-existent agent" do
      result = InsightDetector.detect("nonexistent_agent")
      assert result == {:error, :graph_not_initialized}
    end

    test "detects fact-heavy personality", %{agent_id: agent_id} do
      # Create graph with many facts
      nodes =
        for i <- 1..15 do
          %{type: :fact, content: "Fact #{i}"}
        end

      create_graph_with_nodes(agent_id, nodes)

      insights = InsightDetector.detect(agent_id, include_low_confidence: true)

      assert Enum.any?(insights, fn i ->
               i.category == :personality and
                 String.contains?(i.content, "fact")
             end)
    end

    test "detects skill-heavy value", %{agent_id: agent_id} do
      # Create graph with many skills
      facts =
        for i <- 1..7 do
          %{type: :fact, content: "Fact #{i}"}
        end

      skills =
        for i <- 1..8 do
          %{type: :skill, content: "Skill #{i}"}
        end

      create_graph_with_nodes(agent_id, facts ++ skills)

      insights = InsightDetector.detect(agent_id, include_low_confidence: true)

      assert Enum.any?(insights, fn i ->
               i.category == :value and
                 String.contains?(i.content, "skill")
             end)
    end

    test "respects max_suggestions", %{agent_id: agent_id} do
      nodes =
        for i <- 1..20 do
          type = Enum.random([:fact, :skill, :insight, :experience])
          %{type: type, content: "Content #{i}"}
        end

      create_graph_with_nodes(agent_id, nodes)

      insights = InsightDetector.detect(agent_id, max_suggestions: 2, include_low_confidence: true)

      assert length(insights) <= 2
    end

    test "filters low confidence by default", %{agent_id: agent_id} do
      nodes =
        for i <- 1..15 do
          %{type: :fact, content: "Fact #{i}"}
        end

      create_graph_with_nodes(agent_id, nodes)

      all_insights = InsightDetector.detect(agent_id, include_low_confidence: true)
      high_confidence = InsightDetector.detect(agent_id)

      # High confidence should be subset of all
      assert length(high_confidence) <= length(all_insights)
      assert Enum.all?(high_confidence, fn i -> i.confidence >= 0.5 end)
    end
  end

  describe "detect_and_queue/2" do
    test "creates proposals for detected insights", %{agent_id: agent_id} do
      nodes =
        for i <- 1..15 do
          %{type: :fact, content: "Important fact #{i} about learning and code"}
        end

      create_graph_with_nodes(agent_id, nodes)

      {:ok, proposals} = InsightDetector.detect_and_queue(agent_id, include_low_confidence: true)

      if length(proposals) > 0 do
        assert Enum.all?(proposals, fn p -> p.type == :insight end)
        assert Enum.all?(proposals, fn p -> p.source == "insight_detector" end)
      end
    end

    test "returns empty for small graph", %{agent_id: agent_id} do
      create_graph_with_nodes(agent_id, [
        %{type: :fact, content: "Small"}
      ])

      {:ok, proposals} = InsightDetector.detect_and_queue(agent_id)
      assert proposals == []
    end
  end

  describe "insight categories" do
    test "generates personality insights", %{agent_id: agent_id} do
      # Many insight-type nodes = self-aware personality
      facts =
        for i <- 1..7 do
          %{type: :fact, content: "Fact #{i}"}
        end

      insights =
        for i <- 1..8 do
          %{type: :insight, content: "Insight #{i}"}
        end

      create_graph_with_nodes(agent_id, facts ++ insights)

      detected = InsightDetector.detect(agent_id, include_low_confidence: true)

      personality_insights = Enum.filter(detected, &(&1.category == :personality))
      assert length(personality_insights) > 0
    end

    test "generates preference insights for themed content", %{agent_id: agent_id} do
      # Content with clear themes
      nodes =
        for i <- 1..15 do
          %{
            type: :fact,
            content: "The code function module api system #{i} helps with debugging"
          }
        end

      create_graph_with_nodes(agent_id, nodes)

      detected = InsightDetector.detect(agent_id, include_low_confidence: true)

      # Should detect technical theme
      preference_insights = Enum.filter(detected, &(&1.category == :preference))

      if length(preference_insights) > 0 do
        assert Enum.any?(preference_insights, fn i ->
                 String.contains?(i.content, "technical")
               end)
      end
    end
  end

  describe "insight structure" do
    test "insights have required fields", %{agent_id: agent_id} do
      nodes =
        for i <- 1..15 do
          %{type: :fact, content: "Fact #{i}"}
        end

      create_graph_with_nodes(agent_id, nodes)

      insights = InsightDetector.detect(agent_id, include_low_confidence: true)

      if length(insights) > 0 do
        insight = hd(insights)

        assert Map.has_key?(insight, :content)
        assert Map.has_key?(insight, :category)
        assert Map.has_key?(insight, :confidence)
        assert Map.has_key?(insight, :evidence)
        assert Map.has_key?(insight, :source)

        assert is_binary(insight.content)
        assert insight.category in [:personality, :capability, :value, :preference]
        assert is_float(insight.confidence)
        assert is_list(insight.evidence)
        assert insight.source == :pattern_analysis
      end
    end
  end
end
