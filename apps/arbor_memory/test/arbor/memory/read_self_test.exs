defmodule Arbor.Memory.ReadSelfTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Memory.Goal
  alias Arbor.Memory.{GoalStore, KnowledgeGraph, SelfKnowledge, WorkingMemory}

  @moduletag :fast

  setup do
    agent_id = "test_agent_#{System.unique_integer([:positive])}"

    # Ensure ETS tables exist
    ensure_table(:arbor_memory_graphs)
    ensure_table(:arbor_working_memory)
    ensure_table(:arbor_memory_preferences)
    ensure_table(:arbor_memory_goals)

    on_exit(fn ->
      safe_delete(:arbor_memory_graphs, agent_id)
      safe_delete(:arbor_working_memory, agent_id)
      safe_delete(:arbor_memory_preferences, agent_id)
      GoalStore.clear_goals(agent_id)
    end)

    %{agent_id: agent_id}
  end

  defp ensure_table(name) do
    if :ets.whereis(name) == :undefined do
      try do
        :ets.new(name, [:named_table, :public, :set])
      rescue
        ArgumentError -> :ok
      end
    end
  end

  defp safe_delete(table, key) do
    if :ets.whereis(table) != :undefined do
      :ets.delete(table, key)
    end
  end

  # ============================================================================
  # :memory_system aspect
  # ============================================================================

  describe "read_self/3 :memory_system" do
    test "returns empty stats when no data", %{agent_id: agent_id} do
      {:ok, result} = Arbor.Memory.read_self(agent_id, :memory_system)

      assert %{memory_system: ms} = result
      assert ms.knowledge_graph.node_count == 0 || ms.knowledge_graph == %{node_count: 0, edge_count: 0}
      assert is_map(ms.working_memory)
      assert is_map(ms.proposals)
    end

    test "returns KG stats when graph exists", %{agent_id: agent_id} do
      graph =
        KnowledgeGraph.new(agent_id)
        |> KnowledgeGraph.add_node(%{type: :fact, content: "Test fact"})
        |> elem(1)
        |> KnowledgeGraph.add_node(%{type: :insight, content: "Test insight"})
        |> elem(1)

      :ets.insert(:arbor_memory_graphs, {agent_id, graph})

      {:ok, result} = Arbor.Memory.read_self(agent_id, :memory_system)

      assert result.memory_system.knowledge_graph.node_count == 2
    end

    test "returns WM stats when working memory exists", %{agent_id: agent_id} do
      wm =
        WorkingMemory.new(agent_id)
        |> WorkingMemory.add_thought("Thought 1")
        |> WorkingMemory.add_thought("Thought 2")

      :ets.insert(:arbor_working_memory, {agent_id, wm})

      {:ok, result} = Arbor.Memory.read_self(agent_id, :memory_system)

      assert result.memory_system.working_memory.thought_count == 2
    end
  end

  # ============================================================================
  # :identity aspect
  # ============================================================================

  describe "read_self/3 :identity" do
    test "returns empty identity when no self-knowledge", %{agent_id: agent_id} do
      {:ok, result} = Arbor.Memory.read_self(agent_id, :identity)

      assert %{identity: id} = result
      assert id.self_knowledge.traits == []
      assert id.self_knowledge.values == []
      assert id.self_knowledge.capability_count == 0
      assert id.total_active_goals == 0
    end

    test "returns active goal counts by type", %{agent_id: agent_id} do
      GoalStore.add_goal(agent_id, "Fix bug", type: :achieve)
      GoalStore.add_goal(agent_id, "Learn Elixir", type: :learn)
      GoalStore.add_goal(agent_id, "Keep tests passing", type: :maintain)
      GoalStore.add_goal(agent_id, "Learn OTP", type: :learn)

      {:ok, result} = Arbor.Memory.read_self(agent_id, :identity)

      assert result.identity.total_active_goals == 4
      assert result.identity.active_goals[:achieve] == 1
      assert result.identity.active_goals[:learn] == 2
      assert result.identity.active_goals[:maintain] == 1
    end
  end

  # ============================================================================
  # :tools aspect
  # ============================================================================

  describe "read_self/3 :tools" do
    test "returns empty capabilities when no self-knowledge", %{agent_id: agent_id} do
      {:ok, result} = Arbor.Memory.read_self(agent_id, :tools)

      assert %{tools: tools} = result
      assert tools.capabilities == []
      assert tools.trust_tier == :trusted
    end

    test "respects trust_tier option", %{agent_id: agent_id} do
      {:ok, result} = Arbor.Memory.read_self(agent_id, :tools, trust_tier: :veteran)

      assert result.tools.trust_tier == :veteran
    end
  end

  # ============================================================================
  # :cognition aspect
  # ============================================================================

  describe "read_self/3 :cognition" do
    test "returns default cognition when nothing initialized", %{agent_id: agent_id} do
      {:ok, result} = Arbor.Memory.read_self(agent_id, :cognition)

      assert %{cognition: cog} = result
      assert is_map(cog.preferences)
      assert cog.working_memory.engagement == 0.5
      assert cog.working_memory.thought_count == 0
    end

    test "returns WM engagement and concerns", %{agent_id: agent_id} do
      wm =
        WorkingMemory.new(agent_id)
        |> WorkingMemory.set_engagement_level(0.9)
        |> WorkingMemory.add_concern("Memory running low")
        |> WorkingMemory.add_curiosity("How does ETS work?")

      :ets.insert(:arbor_working_memory, {agent_id, wm})

      {:ok, result} = Arbor.Memory.read_self(agent_id, :cognition)

      assert result.cognition.working_memory.engagement == 0.9
      assert length(result.cognition.working_memory.concerns) == 1
      assert length(result.cognition.working_memory.curiosity) == 1
    end
  end

  # ============================================================================
  # :all aspect
  # ============================================================================

  describe "read_self/3 :all" do
    test "aggregates all aspects", %{agent_id: agent_id} do
      {:ok, result} = Arbor.Memory.read_self(agent_id, :all)

      assert Map.has_key?(result, :memory_system)
      assert Map.has_key?(result, :identity)
      assert Map.has_key?(result, :tools)
      assert Map.has_key?(result, :cognition)
    end

    test "default aspect is :all", %{agent_id: agent_id} do
      {:ok, result} = Arbor.Memory.read_self(agent_id)

      assert Map.has_key?(result, :memory_system)
      assert Map.has_key?(result, :identity)
      assert Map.has_key?(result, :tools)
      assert Map.has_key?(result, :cognition)
    end
  end

  # ============================================================================
  # Unknown aspect
  # ============================================================================

  describe "read_self/3 unknown aspect" do
    test "returns error for unknown aspect", %{agent_id: agent_id} do
      {:ok, result} = Arbor.Memory.read_self(agent_id, :nonexistent)

      assert result.error =~ "Unknown aspect"
    end
  end
end
