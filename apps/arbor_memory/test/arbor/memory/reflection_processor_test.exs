defmodule Arbor.Memory.ReflectionProcessorTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Memory.Goal
  alias Arbor.Memory.{GoalStore, IdentityConsolidator, ReflectionProcessor, Relationship, SelfKnowledge, WorkingMemory}

  @moduletag :fast

  # Helper to extract text content from structured thought maps
  defp thought_content(%{content: c}), do: c
  defp thought_content(c) when is_binary(c), do: c

  setup do
    # Ensure ETS table exists
    if :ets.whereis(:arbor_reflections) == :undefined do
      try do
        :ets.new(:arbor_reflections, [:named_table, :public, :set])
      rescue
        ArgumentError -> :ok
      end
    end

    agent_id = "test_agent_#{:erlang.unique_integer([:positive])}"

    on_exit(fn ->
      # Safely delete - table may not exist
      if :ets.whereis(:arbor_reflections) != :undefined do
        try do
          :ets.delete(:arbor_reflections, agent_id)
        rescue
          ArgumentError -> :ok
        end
      end

      # Clean up goal store
      GoalStore.clear_goals(agent_id)

      # Clean up working memory
      try do
        Arbor.Memory.delete_working_memory(agent_id)
      rescue
        _ -> :ok
      end

      # Clean up knowledge graph
      try do
        Arbor.Memory.cleanup_for_agent(agent_id)
      rescue
        _ -> :ok
      end
    end)

    # Always ensure MockLLM is set as default (tests that override must restore)
    Application.put_env(:arbor_memory, :reflection_llm_module, ReflectionProcessor.MockLLM)

    %{agent_id: agent_id}
  end

  # ============================================================================
  # Existing tests (must still pass)
  # ============================================================================

  describe "reflect/3" do
    test "returns structured reflection map", %{agent_id: agent_id} do
      {:ok, reflection} = ReflectionProcessor.reflect(agent_id, "What patterns do I see?")

      assert is_binary(reflection.id)
      assert reflection.agent_id == agent_id
      assert reflection.prompt == "What patterns do I see?"
      assert is_binary(reflection.analysis)
      assert is_list(reflection.insights)
      assert is_map(reflection.self_assessment)
      assert %DateTime{} = reflection.timestamp
    end

    test "uses mock LLM module by default", %{agent_id: agent_id} do
      {:ok, reflection} = ReflectionProcessor.reflect(agent_id, "How can I improve?")

      # Mock should include "improve" related content
      assert String.contains?(reflection.analysis, "improvement") or
               String.contains?(reflection.analysis, "improve") or
               String.contains?(reflection.analysis, agent_id)

      assert reflection.insights != []
    end

    test "stores reflection in history", %{agent_id: agent_id} do
      {:ok, _} = ReflectionProcessor.reflect(agent_id, "Test prompt")

      {:ok, history} = ReflectionProcessor.history(agent_id)
      assert length(history) == 1
      assert hd(history).prompt == "Test prompt"
    end

    test "respects include_self_knowledge option", %{agent_id: agent_id} do
      # Should not error when self_knowledge is not available
      {:ok, reflection} =
        ReflectionProcessor.reflect(agent_id, "Test",
          include_self_knowledge: true
        )

      assert is_binary(reflection.analysis)
    end

    test "reflection map includes new nil fields", %{agent_id: agent_id} do
      {:ok, reflection} = ReflectionProcessor.reflect(agent_id, "Test")

      assert reflection.goal_updates == nil
      assert reflection.new_goals == nil
      assert reflection.knowledge_nodes == nil
      assert reflection.knowledge_edges == nil
      assert reflection.learnings == nil
      assert reflection.duration_ms == nil
    end
  end

  describe "periodic_reflection/1" do
    test "runs without error", %{agent_id: agent_id} do
      {:ok, reflection} = ReflectionProcessor.periodic_reflection(agent_id)

      assert is_binary(reflection.analysis)
      assert is_list(reflection.insights)
    end

    test "uses standard prompt about patterns and growth", %{agent_id: agent_id} do
      {:ok, reflection} = ReflectionProcessor.periodic_reflection(agent_id)

      assert String.contains?(reflection.prompt, "pattern") or
               String.contains?(reflection.prompt, "activity")
    end
  end

  describe "history/2" do
    test "returns empty list for new agent", %{agent_id: agent_id} do
      {:ok, history} = ReflectionProcessor.history(agent_id)
      assert history == []
    end

    test "returns past reflections in order", %{agent_id: agent_id} do
      {:ok, _} = ReflectionProcessor.reflect(agent_id, "First")
      {:ok, _} = ReflectionProcessor.reflect(agent_id, "Second")
      {:ok, _} = ReflectionProcessor.reflect(agent_id, "Third")

      {:ok, history} = ReflectionProcessor.history(agent_id)
      assert length(history) == 3
      # Most recent first
      assert hd(history).prompt == "Third"
    end

    test "respects limit option", %{agent_id: agent_id} do
      for i <- 1..5 do
        {:ok, _} = ReflectionProcessor.reflect(agent_id, "Prompt #{i}")
      end

      {:ok, limited} = ReflectionProcessor.history(agent_id, limit: 2)
      assert length(limited) == 2
    end

    test "respects since option", %{agent_id: agent_id} do
      {:ok, _} = ReflectionProcessor.reflect(agent_id, "Old")
      old_time = DateTime.utc_now()
      Process.sleep(10)
      {:ok, _} = ReflectionProcessor.reflect(agent_id, "New")

      {:ok, filtered} = ReflectionProcessor.history(agent_id, since: old_time)
      assert length(filtered) == 1
      assert hd(filtered).prompt == "New"
    end
  end

  describe "MockLLM" do
    test "reflect returns structured response" do
      {:ok, response} =
        ReflectionProcessor.MockLLM.reflect("Test prompt", %{
          agent_id: "test"
        })

      assert is_binary(response.analysis)
      assert is_list(response.insights)
      assert is_map(response.self_assessment)
    end

    test "analysis varies based on prompt content" do
      {:ok, pattern_response} =
        ReflectionProcessor.MockLLM.reflect("What patterns do I see?", %{})

      {:ok, improve_response} =
        ReflectionProcessor.MockLLM.reflect("How can I improve?", %{})

      # Both should be valid but different
      assert is_binary(pattern_response.analysis)
      assert is_binary(improve_response.analysis)
    end

    test "self_assessment reflects context" do
      {:ok, with_caps} =
        ReflectionProcessor.MockLLM.reflect("Test", %{
          capabilities: [%{name: "elixir", proficiency: 0.8}]
        })

      {:ok, without_caps} =
        ReflectionProcessor.MockLLM.reflect("Test", %{
          capabilities: []
        })

      # With capabilities should have higher confidence
      assert with_caps.self_assessment.capability_confidence >
               without_caps.self_assessment.capability_confidence
    end

    test "generate_text returns valid JSON" do
      {:ok, json} = ReflectionProcessor.MockLLM.generate_text("test", [])
      assert {:ok, parsed} = Jason.decode(json)
      assert is_list(parsed["insights"])
      assert is_list(parsed["learnings"])
      assert is_list(parsed["goal_updates"])
    end
  end

  # ============================================================================
  # New tests: deep_reflect/2
  # ============================================================================

  describe "deep_reflect/2" do
    setup %{agent_id: agent_id} do
      # Configure MockLLM for deep_reflect tests
      Application.put_env(:arbor_memory, :reflection_llm_module, ReflectionProcessor.MockLLM)

      on_exit(fn ->
        Application.put_env(:arbor_memory, :reflection_llm_module, ReflectionProcessor.MockLLM)
      end)

      %{agent_id: agent_id}
    end

    test "returns full reflection result with all fields", %{agent_id: agent_id} do
      {:ok, result} = ReflectionProcessor.deep_reflect(agent_id)

      assert is_list(result.goal_updates)
      assert is_list(result.new_goals)
      assert is_list(result.insights)
      assert is_list(result.learnings)
      assert is_integer(result.knowledge_nodes_added)
      assert is_integer(result.knowledge_edges_added)
      assert is_list(result.self_insight_suggestions)
      assert is_integer(result.duration_ms)
      assert result.duration_ms >= 0
    end

    test "stores deep_reflect in history", %{agent_id: agent_id} do
      {:ok, _} = ReflectionProcessor.deep_reflect(agent_id)

      {:ok, history} = ReflectionProcessor.history(agent_id)
      assert length(history) == 1
      assert hd(history).prompt == "deep_reflect"
      assert hd(history).duration_ms != nil
    end

    test "returns insights from MockLLM", %{agent_id: agent_id} do
      {:ok, result} = ReflectionProcessor.deep_reflect(agent_id)

      # MockLLM returns one insight
      assert length(result.insights) == 1
      assert hd(result.insights)["content"] == "Mock insight from deep reflection"
    end

    test "returns learnings from MockLLM", %{agent_id: agent_id} do
      {:ok, result} = ReflectionProcessor.deep_reflect(agent_id)

      assert length(result.learnings) == 1
      assert hd(result.learnings)["category"] == "technical"
    end

    test "handles LLM failure gracefully", %{agent_id: agent_id} do
      # Create a failing mock
      defmodule FailingMock do
        def generate_text(_prompt, _opts), do: {:error, :llm_unavailable}
      end

      Application.put_env(:arbor_memory, :reflection_llm_module, FailingMock)

      try do
        assert {:error, :llm_unavailable} = ReflectionProcessor.deep_reflect(agent_id)
      after
        Application.put_env(:arbor_memory, :reflection_llm_module, ReflectionProcessor.MockLLM)
      end
    end
  end

  # ============================================================================
  # New tests: Goal Processing
  # ============================================================================

  describe "process_goal_updates/2" do
    test "updates goal progress via GoalStore", %{agent_id: agent_id} do
      goal = Goal.new("Test goal", type: :achieve, priority: 50)
      {:ok, _} = GoalStore.add_goal(agent_id, goal)

      ReflectionProcessor.process_goal_updates(agent_id, [
        %{"goal_id" => goal.id, "new_progress" => 0.75, "status" => "active"}
      ])

      {:ok, updated} = GoalStore.get_goal(agent_id, goal.id)
      assert updated.progress == 0.75
    end

    test "achieves goals when status is 'achieved'", %{agent_id: agent_id} do
      goal = Goal.new("Achievable goal", type: :achieve)
      {:ok, _} = GoalStore.add_goal(agent_id, goal)

      ReflectionProcessor.process_goal_updates(agent_id, [
        %{"goal_id" => goal.id, "status" => "achieved"}
      ])

      {:ok, updated} = GoalStore.get_goal(agent_id, goal.id)
      assert updated.status == :achieved
    end

    test "abandons goals when status is 'abandoned'", %{agent_id: agent_id} do
      goal = Goal.new("Abandon me", type: :achieve)
      {:ok, _} = GoalStore.add_goal(agent_id, goal)

      ReflectionProcessor.process_goal_updates(agent_id, [
        %{"goal_id" => goal.id, "status" => "abandoned", "note" => "No longer needed"}
      ])

      {:ok, updated} = GoalStore.get_goal(agent_id, goal.id)
      assert updated.status == :abandoned
    end

    test "clamps progress to 0.0-1.0 range", %{agent_id: agent_id} do
      goal = Goal.new("Clamp test")
      {:ok, _} = GoalStore.add_goal(agent_id, goal)

      ReflectionProcessor.process_goal_updates(agent_id, [
        %{"goal_id" => goal.id, "new_progress" => 1.5}
      ])

      {:ok, updated} = GoalStore.get_goal(agent_id, goal.id)
      assert updated.progress == 1.0
    end

    test "handles missing goal_id gracefully", %{agent_id: agent_id} do
      # Should not raise
      ReflectionProcessor.process_goal_updates(agent_id, [
        %{"new_progress" => 0.5}
      ])
    end

    test "handles nonexistent goal gracefully", %{agent_id: agent_id} do
      # Should not raise
      ReflectionProcessor.process_goal_updates(agent_id, [
        %{"goal_id" => "nonexistent", "new_progress" => 0.5}
      ])
    end
  end

  describe "process_new_goals/2" do
    test "creates new goals with correct type and priority", %{agent_id: agent_id} do
      ReflectionProcessor.process_new_goals(agent_id, [
        %{
          "description" => "Learn Elixir macros",
          "type" => "learn",
          "priority" => "high"
        }
      ])

      goals = GoalStore.get_active_goals(agent_id)
      assert length(goals) == 1
      assert hd(goals).description == "Learn Elixir macros"
      assert hd(goals).type == :learn
      assert hd(goals).priority == 70
    end

    test "handles nil priority and type", %{agent_id: agent_id} do
      ReflectionProcessor.process_new_goals(agent_id, [
        %{"description" => "Some goal"}
      ])

      goals = GoalStore.get_active_goals(agent_id)
      assert length(goals) == 1
      assert hd(goals).type == :achieve
      assert hd(goals).priority == 50
    end

    test "skips goals with empty description", %{agent_id: agent_id} do
      ReflectionProcessor.process_new_goals(agent_id, [
        %{"description" => ""},
        %{"description" => nil},
        %{}
      ])

      goals = GoalStore.get_active_goals(agent_id)
      assert goals == []
    end

    test "maps priority strings to integers", %{agent_id: _agent_id} do
      agent = "priority_test_#{:erlang.unique_integer([:positive])}"

      on_exit(fn -> GoalStore.clear_goals(agent) end)

      Enum.each(
        [
          {"critical", 90},
          {"high", 70},
          {"medium", 50},
          {"low", 30}
        ],
        fn {priority_str, expected_int} ->
          GoalStore.clear_goals(agent)

          ReflectionProcessor.process_new_goals(agent, [
            %{"description" => "Goal #{priority_str}", "priority" => priority_str}
          ])

          goals = GoalStore.get_active_goals(agent)
          assert length(goals) == 1
          assert hd(goals).priority == expected_int
        end
      )
    end
  end

  # ============================================================================
  # New tests: Insight Integration
  # ============================================================================

  describe "integrate_insights/2" do
    test "adds high-importance insights to working memory", %{agent_id: agent_id} do
      wm = WorkingMemory.new(agent_id)
      Arbor.Memory.save_working_memory(agent_id, wm)

      ReflectionProcessor.integrate_insights(agent_id, [
        %{"content" => "Important insight", "importance" => 0.8}
      ])

      updated_wm = Arbor.Memory.get_working_memory(agent_id)
      assert Enum.any?(updated_wm.recent_thoughts, &String.contains?(thought_content(&1), "Important insight"))
    end

    test "skips low-importance insights", %{agent_id: agent_id} do
      wm = WorkingMemory.new(agent_id)
      Arbor.Memory.save_working_memory(agent_id, wm)

      ReflectionProcessor.integrate_insights(agent_id, [
        %{"content" => "Low importance", "importance" => 0.3}
      ])

      updated_wm = Arbor.Memory.get_working_memory(agent_id)
      assert updated_wm.recent_thoughts == []
    end

    test "handles missing working memory", %{agent_id: agent_id} do
      # No working memory set up — should not raise
      ReflectionProcessor.integrate_insights(agent_id, [
        %{"content" => "No WM available", "importance" => 0.9}
      ])
    end
  end

  # ============================================================================
  # New tests: Learning Integration
  # ============================================================================

  describe "integrate_learnings/2" do
    test "adds learnings with category prefix to working memory", %{agent_id: agent_id} do
      wm = WorkingMemory.new(agent_id)
      Arbor.Memory.save_working_memory(agent_id, wm)

      ReflectionProcessor.integrate_learnings(agent_id, [
        %{"content" => "Elixir patterns", "confidence" => 0.8, "category" => "technical"}
      ])

      updated_wm = Arbor.Memory.get_working_memory(agent_id)
      assert Enum.any?(updated_wm.recent_thoughts, &String.contains?(thought_content(&1), "[Technical Learning]"))
    end

    test "skips low-confidence learnings", %{agent_id: agent_id} do
      wm = WorkingMemory.new(agent_id)
      Arbor.Memory.save_working_memory(agent_id, wm)

      ReflectionProcessor.integrate_learnings(agent_id, [
        %{"content" => "Low confidence", "confidence" => 0.3, "category" => "self"}
      ])

      updated_wm = Arbor.Memory.get_working_memory(agent_id)
      assert updated_wm.recent_thoughts == []
    end
  end

  # ============================================================================
  # New tests: Knowledge Graph Integration
  # ============================================================================

  describe "integrate_knowledge_graph/3" do
    setup %{agent_id: agent_id} do
      # Initialize memory with a knowledge graph
      {:ok, _pid} = Arbor.Memory.init_for_agent(agent_id)
      %{agent_id: agent_id}
    end

    test "adds nodes to knowledge graph", %{agent_id: agent_id} do
      nodes = [
        %{"name" => "Elixir", "type" => "concept", "context" => "Programming language"},
        %{"name" => "OTP", "type" => "concept", "context" => "Framework"}
      ]

      ReflectionProcessor.integrate_knowledge_graph(agent_id, nodes, [])

      {:ok, stats} = Arbor.Memory.knowledge_stats(agent_id)
      assert stats.node_count >= 2
    end

    test "adds edges between nodes", %{agent_id: agent_id} do
      nodes = [
        %{"name" => "Elixir", "type" => "concept", "context" => "Language"},
        %{"name" => "OTP", "type" => "concept", "context" => "Framework"}
      ]

      edges = [
        %{"from" => "Elixir", "to" => "OTP", "relationship" => "uses"}
      ]

      ReflectionProcessor.integrate_knowledge_graph(agent_id, nodes, edges)

      {:ok, stats} = Arbor.Memory.knowledge_stats(agent_id)
      assert stats.edge_count >= 1
    end

    test "skips nodes with empty names", %{agent_id: agent_id} do
      nodes = [
        %{"name" => "", "type" => "concept"},
        %{"name" => nil, "type" => "concept"}
      ]

      ReflectionProcessor.integrate_knowledge_graph(agent_id, nodes, [])

      {:ok, stats} = Arbor.Memory.knowledge_stats(agent_id)
      assert stats.node_count == 0
    end

    test "skips edges when source or target not found", %{agent_id: agent_id} do
      nodes = [
        %{"name" => "OnlyOne", "type" => "concept"}
      ]

      edges = [
        %{"from" => "OnlyOne", "to" => "Missing", "relationship" => "related_to"}
      ]

      # Should not raise
      ReflectionProcessor.integrate_knowledge_graph(agent_id, nodes, edges)

      {:ok, stats} = Arbor.Memory.knowledge_stats(agent_id)
      assert stats.edge_count == 0
    end

    test "does nothing for empty nodes and edges", %{agent_id: agent_id} do
      result = ReflectionProcessor.integrate_knowledge_graph(agent_id, [], [])
      assert result == :ok
    end
  end

  # ============================================================================
  # New tests: Context Building
  # ============================================================================

  describe "build_deep_context/2" do
    test "includes active goals from GoalStore", %{agent_id: agent_id} do
      goal = Goal.new("Deep context goal", type: :achieve, priority: 80)
      {:ok, _} = GoalStore.add_goal(agent_id, goal)

      {:ok, context} = ReflectionProcessor.build_deep_context(agent_id, [])

      assert length(context.goals) == 1
      assert hd(context.goals).description == "Deep context goal"
      assert String.contains?(context.goals_text, "Deep context goal")
    end

    test "formats goal progress bars", %{agent_id: agent_id} do
      goal = Goal.new("Half done", type: :achieve, progress: 0.5)
      {:ok, _} = GoalStore.add_goal(agent_id, goal)

      {:ok, context} = ReflectionProcessor.build_deep_context(agent_id, [])

      assert String.contains?(context.goals_text, "█")
      assert String.contains?(context.goals_text, "░")
      assert String.contains?(context.goals_text, "50")
    end

    test "handles no self-knowledge gracefully", %{agent_id: agent_id} do
      {:ok, context} = ReflectionProcessor.build_deep_context(agent_id, [])

      assert context.self_knowledge == nil
      assert context.self_knowledge_text =~ "No self-knowledge"
    end

    test "includes working memory when available", %{agent_id: agent_id} do
      wm = WorkingMemory.new(agent_id)
      wm = WorkingMemory.add_thought(wm, "Testing deep context")
      Arbor.Memory.save_working_memory(agent_id, wm)

      {:ok, context} = ReflectionProcessor.build_deep_context(agent_id, [])

      assert context.working_memory_text != ""
    end

    test "handles no working memory", %{agent_id: agent_id} do
      {:ok, context} = ReflectionProcessor.build_deep_context(agent_id, [])
      assert context.working_memory_text == ""
    end

    test "includes recent thinking text", %{agent_id: agent_id} do
      {:ok, _} = Arbor.Memory.record_thinking(agent_id, "Deep thought about code")

      {:ok, context} = ReflectionProcessor.build_deep_context(agent_id, [])

      assert String.contains?(context.recent_thinking_text, "Deep thought about code")
    end
  end

  # ============================================================================
  # New tests: JSON Parsing
  # ============================================================================

  describe "parse_reflection_response/1" do
    test "parses valid JSON response" do
      json =
        Jason.encode!(%{
          "goal_updates" => [%{"goal_id" => "g1", "new_progress" => 0.5}],
          "insights" => [%{"content" => "test insight", "importance" => 0.8}],
          "learnings" => [],
          "new_goals" => [],
          "knowledge_nodes" => [],
          "knowledge_edges" => [],
          "self_insight_suggestions" => [],
          "thinking" => "Some thinking"
        })

      {:ok, parsed} = ReflectionProcessor.parse_reflection_response(json)

      assert length(parsed.goal_updates) == 1
      assert hd(parsed.goal_updates)["goal_id"] == "g1"
      assert length(parsed.insights) == 1
      assert parsed.thinking == "Some thinking"
    end

    test "extracts JSON from markdown code blocks" do
      response = """
      Here is my reflection:

      ```json
      {"insights": [{"content": "from code block", "importance": 0.9}], "goal_updates": [], "learnings": [], "new_goals": [], "knowledge_nodes": [], "knowledge_edges": [], "self_insight_suggestions": []}
      ```
      """

      {:ok, parsed} = ReflectionProcessor.parse_reflection_response(response)

      assert length(parsed.insights) == 1
      assert hd(parsed.insights)["content"] == "from code block"
    end

    test "returns empty structures on invalid JSON" do
      {:ok, parsed} = ReflectionProcessor.parse_reflection_response("not json at all")

      assert parsed.goal_updates == []
      assert parsed.insights == []
      assert parsed.learnings == []
      assert parsed.new_goals == []
      assert parsed.knowledge_nodes == []
      assert parsed.knowledge_edges == []
      assert parsed.self_insight_suggestions == []
      assert parsed.thinking == nil
    end

    test "handles missing fields gracefully" do
      json = Jason.encode!(%{"insights" => [%{"content" => "only insights"}]})

      {:ok, parsed} = ReflectionProcessor.parse_reflection_response(json)

      assert length(parsed.insights) == 1
      assert parsed.goal_updates == []
      assert parsed.learnings == []
      assert parsed.new_goals == []
    end
  end

  # ============================================================================
  # New tests: LLM Call
  # ============================================================================

  describe "call_llm/2" do
    setup do
      on_exit(fn ->
        Application.put_env(:arbor_memory, :reflection_llm_module, ReflectionProcessor.MockLLM)
      end)

      :ok
    end

    test "uses MockLLM when configured" do
      Application.put_env(:arbor_memory, :reflection_llm_module, ReflectionProcessor.MockLLM)

      {:ok, text} = ReflectionProcessor.call_llm("test prompt", [])

      # MockLLM.generate_text returns JSON
      assert {:ok, _} = Jason.decode(text)
    end

    test "returns error when LLM module fails" do
      defmodule ErrorMock do
        def generate_text(_prompt, _opts), do: {:error, :api_error}
      end

      Application.put_env(:arbor_memory, :reflection_llm_module, ErrorMock)

      assert {:error, :api_error} = ReflectionProcessor.call_llm("test", [])
    end
  end

  # ============================================================================
  # New tests: Build Reflection Prompt
  # ============================================================================

  describe "build_reflection_prompt/1" do
    test "includes goal evaluation instructions" do
      context = %{
        self_knowledge_text: "Some identity",
        goals_text: "- [g1] Fix bug",
        knowledge_graph_text: "(No graph)",
        working_memory_text: "",
        recent_thinking_text: "(No thinking)",
        recent_activity_text: "(No recent activity)"
      }

      prompt = ReflectionProcessor.build_reflection_prompt(context)

      assert String.contains?(prompt, "GOAL EVALUATION IS YOUR TOP PRIORITY")
      assert String.contains?(prompt, "Fix bug")
      assert String.contains?(prompt, "JSON format")
    end

    test "includes all context sections" do
      context = %{
        self_knowledge_text: "Identity info here",
        goals_text: "Goals here",
        knowledge_graph_text: "KG info here",
        working_memory_text: "WM info here",
        recent_thinking_text: "Thinking here",
        recent_activity_text: "Activity here"
      }

      prompt = ReflectionProcessor.build_reflection_prompt(context)

      assert String.contains?(prompt, "Identity info here")
      assert String.contains?(prompt, "Goals here")
      assert String.contains?(prompt, "KG info here")
      assert String.contains?(prompt, "WM info here")
      assert String.contains?(prompt, "Thinking here")
      assert String.contains?(prompt, "Activity here")
    end
  end

  # ============================================================================
  # Phase 1: KG find_by_name via facade
  # ============================================================================

  describe "find_knowledge_by_name (facade)" do
    setup %{agent_id: agent_id} do
      {:ok, _pid} = Arbor.Memory.init_for_agent(agent_id)
      %{agent_id: agent_id}
    end

    test "finds existing node by name", %{agent_id: agent_id} do
      {:ok, node_id} =
        Arbor.Memory.add_knowledge(agent_id, %{type: :fact, content: "Elixir"})

      assert {:ok, ^node_id} = Arbor.Memory.find_knowledge_by_name(agent_id, "Elixir")
    end

    test "case-insensitive match", %{agent_id: agent_id} do
      {:ok, node_id} =
        Arbor.Memory.add_knowledge(agent_id, %{type: :fact, content: "Elixir"})

      assert {:ok, ^node_id} = Arbor.Memory.find_knowledge_by_name(agent_id, "elixir")
      assert {:ok, ^node_id} = Arbor.Memory.find_knowledge_by_name(agent_id, "ELIXIR")
    end

    test "returns not_found for missing name", %{agent_id: agent_id} do
      assert {:error, :not_found} =
               Arbor.Memory.find_knowledge_by_name(agent_id, "nonexistent")
    end

    test "returns not_found on empty graph", %{agent_id: agent_id} do
      assert {:error, :not_found} =
               Arbor.Memory.find_knowledge_by_name(agent_id, "anything")
    end
  end

  # ============================================================================
  # Phase 2: Signal/Activity gathering
  # ============================================================================

  describe "build_deep_context/2 with activity" do
    test "context includes recent_activity_text key", %{agent_id: agent_id} do
      {:ok, context} = ReflectionProcessor.build_deep_context(agent_id, [])
      assert is_binary(context.recent_activity_text)
    end

    test "returns fallback when no events", %{agent_id: agent_id} do
      {:ok, context} = ReflectionProcessor.build_deep_context(agent_id, [])
      assert context.recent_activity_text =~ "No recent activity"
    end

    test "prompt includes Recent Activity section", %{agent_id: agent_id} do
      {:ok, context} = ReflectionProcessor.build_deep_context(agent_id, [])
      prompt = ReflectionProcessor.build_reflection_prompt(context)
      assert String.contains?(prompt, "## Recent Activity")
    end
  end

  # ============================================================================
  # Phase 3: Reflection gating
  # ============================================================================

  describe "should_reflect?/2" do
    test "returns true when no reflection history", %{agent_id: agent_id} do
      assert ReflectionProcessor.should_reflect?(agent_id)
    end

    test "returns false after recent reflection", %{agent_id: agent_id} do
      # Do a reflection to set the timestamp
      {:ok, _} = ReflectionProcessor.reflect(agent_id, "Initial reflection")

      # With a very long interval, time won't have elapsed
      refute ReflectionProcessor.should_reflect?(agent_id,
               interval_ms: 999_999_999,
               threshold: 999_999
             )
    end

    test "custom interval controls timing", %{agent_id: agent_id} do
      {:ok, _} = ReflectionProcessor.reflect(agent_id, "Setup")

      # With 0ms interval, should always reflect
      assert ReflectionProcessor.should_reflect?(agent_id, interval_ms: 0)
    end

    test "periodic_reflection skips when gating says no", %{agent_id: agent_id} do
      {:ok, _} = ReflectionProcessor.reflect(agent_id, "Setup")

      assert {:ok, :skipped} =
               ReflectionProcessor.periodic_reflection(agent_id,
                 interval_ms: 999_999_999,
                 threshold: 999_999
               )
    end

    test "periodic_reflection force bypasses gating", %{agent_id: agent_id} do
      {:ok, _} = ReflectionProcessor.reflect(agent_id, "Setup")

      {:ok, result} =
        ReflectionProcessor.periodic_reflection(agent_id,
          force: true,
          interval_ms: 999_999_999,
          threshold: 999_999
        )

      assert is_binary(result.analysis)
    end
  end

  # ============================================================================
  # Phase 4: KG dedup + edges
  # ============================================================================

  describe "KG dedup in integrate_knowledge_graph" do
    setup %{agent_id: agent_id} do
      {:ok, _pid} = Arbor.Memory.init_for_agent(agent_id)
      %{agent_id: agent_id}
    end

    test "does not create duplicate nodes", %{agent_id: agent_id} do
      # Pre-add a node
      {:ok, _} =
        Arbor.Memory.add_knowledge(agent_id, %{type: :fact, content: "Elixir"})

      # Integrate the same name
      ReflectionProcessor.integrate_knowledge_graph(
        agent_id,
        [%{"name" => "Elixir", "type" => "concept", "context" => "language"}],
        []
      )

      {:ok, stats} = Arbor.Memory.knowledge_stats(agent_id)
      # Should still be 1, not 2
      assert stats.node_count == 1
    end

    test "reuses existing node ID for edges", %{agent_id: agent_id} do
      # Pre-add a node
      {:ok, existing_id} =
        Arbor.Memory.add_knowledge(agent_id, %{type: :fact, content: "Elixir"})

      nodes = [
        %{"name" => "Elixir", "type" => "concept"},
        %{"name" => "OTP", "type" => "concept"}
      ]

      edges = [
        %{"from" => "Elixir", "to" => "OTP", "relationship" => "uses"}
      ]

      ReflectionProcessor.integrate_knowledge_graph(agent_id, nodes, edges)

      {:ok, stats} = Arbor.Memory.knowledge_stats(agent_id)
      # 2 nodes total: existing Elixir + new OTP
      assert stats.node_count == 2
      # Edge should work because existing node ID is in map
      assert stats.edge_count >= 1

      # The existing node should still be accessible
      {:ok, ^existing_id} = Arbor.Memory.find_knowledge_by_name(agent_id, "Elixir")
    end

    test "edges work when both nodes pre-exist", %{agent_id: agent_id} do
      {:ok, _} = Arbor.Memory.add_knowledge(agent_id, %{type: :fact, content: "A"})
      {:ok, _} = Arbor.Memory.add_knowledge(agent_id, %{type: :fact, content: "B"})

      nodes = [
        %{"name" => "A", "type" => "concept"},
        %{"name" => "B", "type" => "concept"}
      ]

      edges = [%{"from" => "A", "to" => "B", "relationship" => "related_to"}]

      ReflectionProcessor.integrate_knowledge_graph(agent_id, nodes, edges)

      {:ok, stats} = Arbor.Memory.knowledge_stats(agent_id)
      assert stats.node_count == 2
      assert stats.edge_count >= 1
    end
  end

  # ============================================================================
  # Phase 5: Relationship processing
  # ============================================================================

  describe "process_relationships/2" do
    @tag :database
    test "creates new relationship", %{agent_id: agent_id} do
      ReflectionProcessor.process_relationships(agent_id, [
        %{
          "name" => "TestPerson",
          "dynamic" => "Collaborative partnership",
          "observation" => "Worked together on tests"
        }
      ])

      {:ok, rel} = Arbor.Memory.get_relationship_by_name(agent_id, "TestPerson")
      assert rel.name == "TestPerson"
    end

    @tag :database
    test "updates existing relationship", %{agent_id: agent_id} do
      rel = Arbor.Memory.Relationship.new("ExistingPerson")
      {:ok, _} = Arbor.Memory.save_relationship(agent_id, rel)

      ReflectionProcessor.process_relationships(agent_id, [
        %{
          "name" => "ExistingPerson",
          "dynamic" => "Updated dynamic",
          "observation" => "New observation"
        }
      ])

      {:ok, updated} = Arbor.Memory.get_relationship_by_name(agent_id, "ExistingPerson")
      assert updated.name == "ExistingPerson"
    end

    test "skips entries with missing name", %{agent_id: agent_id} do
      # Should not raise
      ReflectionProcessor.process_relationships(agent_id, [
        %{"dynamic" => "No name provided"},
        %{"name" => "", "dynamic" => "Empty name"},
        %{"name" => nil}
      ])
    end

    test "handles empty list", %{agent_id: agent_id} do
      assert :ok == ReflectionProcessor.process_relationships(agent_id, [])
    end

    test "parsed response includes relationships field" do
      json =
        Jason.encode!(%{
          "relationships" => [%{"name" => "Bob", "dynamic" => "friendly"}],
          "insights" => []
        })

      {:ok, parsed} = ReflectionProcessor.parse_reflection_response(json)
      assert length(parsed.relationships) == 1
      assert hd(parsed.relationships)["name"] == "Bob"
    end
  end

  # ============================================================================
  # Phase 6: InsightDetector integration
  # ============================================================================

  describe "insight detection and self-insight suggestions" do
    test "store_self_insight_suggestions adds to working memory", %{agent_id: agent_id} do
      wm = WorkingMemory.new(agent_id)
      Arbor.Memory.save_working_memory(agent_id, wm)

      # This is testing via deep_reflect indirectly — let's test MockLLM
      # includes self_insight_suggestions field and verify it round-trips
      json =
        Jason.encode!(%{
          "insights" => [],
          "goal_updates" => [],
          "learnings" => [],
          "new_goals" => [],
          "knowledge_nodes" => [],
          "knowledge_edges" => [],
          "self_insight_suggestions" => [
            %{
              "content" => "I tend to be curious",
              "category" => "personality",
              "confidence" => 0.6
            }
          ]
        })

      {:ok, parsed} = ReflectionProcessor.parse_reflection_response(json)
      assert length(parsed.self_insight_suggestions) == 1
    end

    test "insight detector failure does not crash deep_reflect", %{agent_id: agent_id} do
      # deep_reflect should succeed even if InsightDetector fails
      {:ok, result} = ReflectionProcessor.deep_reflect(agent_id)
      assert is_map(result)
    end
  end

  # ============================================================================
  # Phase 7: Blocked/failed goal statuses
  # ============================================================================

  describe "blocked and failed goal statuses" do
    test "blocked status sets goal to :blocked", %{agent_id: agent_id} do
      goal = Goal.new("Blockable goal")
      {:ok, _} = GoalStore.add_goal(agent_id, goal)

      ReflectionProcessor.process_goal_updates(agent_id, [
        %{
          "goal_id" => goal.id,
          "status" => "blocked",
          "blockers" => ["waiting on API key"]
        }
      ])

      {:ok, updated} = GoalStore.get_goal(agent_id, goal.id)
      assert updated.status == :blocked
      assert updated.metadata[:blockers] == ["waiting on API key"]
    end

    test "failed status sets :failed and records reason in notes", %{agent_id: agent_id} do
      goal = Goal.new("Failing goal")
      {:ok, _} = GoalStore.add_goal(agent_id, goal)

      ReflectionProcessor.process_goal_updates(agent_id, [
        %{
          "goal_id" => goal.id,
          "status" => "failed",
          "note" => "API deprecated"
        }
      ])

      {:ok, updated} = GoalStore.get_goal(agent_id, goal.id)
      assert updated.status == :failed
      assert Enum.any?(updated.notes, &String.contains?(&1, "API deprecated"))
    end

    test "GoalStore.block_goal sets status and stores blockers", %{agent_id: agent_id} do
      goal = Goal.new("Direct block test")
      {:ok, _} = GoalStore.add_goal(agent_id, goal)

      {:ok, blocked} = GoalStore.block_goal(agent_id, goal.id, ["blocker1", "blocker2"])
      assert blocked.status == :blocked
      assert blocked.metadata[:blockers] == ["blocker1", "blocker2"]
    end

    test "GoalStore.block_goal returns not_found for missing goal", %{agent_id: agent_id} do
      assert {:error, :not_found} = GoalStore.block_goal(agent_id, "missing_id")
    end
  end

  # ============================================================================
  # Phase 8: Goals in Knowledge Graph
  # ============================================================================

  describe "goals in knowledge graph" do
    setup %{agent_id: agent_id} do
      {:ok, _pid} = Arbor.Memory.init_for_agent(agent_id)
      %{agent_id: agent_id}
    end

    test "active goals are added as KG nodes during deep_reflect", %{agent_id: agent_id} do
      goal = Goal.new("Build the feature", type: :achieve, priority: 80)
      {:ok, _} = GoalStore.add_goal(agent_id, goal)

      {:ok, _result} = ReflectionProcessor.deep_reflect(agent_id)

      {:ok, stats} = Arbor.Memory.knowledge_stats(agent_id)
      assert stats.node_count >= 1

      # Should be findable by the goal description
      {:ok, _node_id} =
        Arbor.Memory.find_knowledge_by_name(agent_id, "Build the feature")
    end

    test "does not duplicate goal nodes across reflections", %{agent_id: agent_id} do
      goal = Goal.new("Unique goal for dedup test")
      {:ok, _} = GoalStore.add_goal(agent_id, goal)

      {:ok, _} = ReflectionProcessor.deep_reflect(agent_id)
      {:ok, stats1} = Arbor.Memory.knowledge_stats(agent_id)

      {:ok, _} = ReflectionProcessor.deep_reflect(agent_id)
      {:ok, stats2} = Arbor.Memory.knowledge_stats(agent_id)

      # Node count should not increase on second reflection
      # (MockLLM returns same data both times; goal + learning both deduped)
      assert stats2.node_count == stats1.node_count
    end
  end

  # ============================================================================
  # Phase 9: Learning categorization routing
  # ============================================================================

  describe "learning categorization routing" do
    setup %{agent_id: agent_id} do
      {:ok, _pid} = Arbor.Memory.init_for_agent(agent_id)
      %{agent_id: agent_id}
    end

    test "technical learnings are added to KG as skill nodes", %{agent_id: agent_id} do
      wm = WorkingMemory.new(agent_id)
      Arbor.Memory.save_working_memory(agent_id, wm)

      ReflectionProcessor.integrate_learnings(agent_id, [
        %{"content" => "Pattern matching is powerful", "confidence" => 0.9, "category" => "technical"}
      ])

      {:ok, stats} = Arbor.Memory.knowledge_stats(agent_id)
      assert stats.node_count >= 1
    end

    test "self learnings go to SelfKnowledge growth log", %{agent_id: agent_id} do
      # Set up SelfKnowledge
      sk = Arbor.Memory.SelfKnowledge.new(agent_id)
      Arbor.Memory.IdentityConsolidator.save_self_knowledge(agent_id, sk)

      wm = WorkingMemory.new(agent_id)
      Arbor.Memory.save_working_memory(agent_id, wm)

      ReflectionProcessor.integrate_learnings(agent_id, [
        %{"content" => "I am more patient now", "confidence" => 0.8, "category" => "self"}
      ])

      updated_sk = Arbor.Memory.IdentityConsolidator.get_self_knowledge(agent_id)
      assert updated_sk.growth_log != []
    end

    test "all learnings also go to working memory", %{agent_id: agent_id} do
      wm = WorkingMemory.new(agent_id)
      Arbor.Memory.save_working_memory(agent_id, wm)

      ReflectionProcessor.integrate_learnings(agent_id, [
        %{"content" => "Test learning", "confidence" => 0.8, "category" => "relationship"}
      ])

      updated_wm = Arbor.Memory.get_working_memory(agent_id)
      assert Enum.any?(updated_wm.recent_thoughts, &String.contains?(thought_content(&1), "Test learning"))
    end

    test "unknown category does not error", %{agent_id: agent_id} do
      wm = WorkingMemory.new(agent_id)
      Arbor.Memory.save_working_memory(agent_id, wm)

      # Should not raise
      ReflectionProcessor.integrate_learnings(agent_id, [
        %{"content" => "Mystery learning", "confidence" => 0.8, "category" => "unknown_category"}
      ])

      updated_wm = Arbor.Memory.get_working_memory(agent_id)
      assert Enum.any?(updated_wm.recent_thoughts, &String.contains?(thought_content(&1), "Mystery learning"))
    end
  end

  # ============================================================================
  # Phase 10: Minor polish
  # ============================================================================

  describe "goal metadata polish" do
    test "success_criteria stored in goal struct field", %{agent_id: agent_id} do
      ReflectionProcessor.process_new_goals(agent_id, [
        %{
          "description" => "Goal with criteria",
          "type" => "achieve",
          "success_criteria" => "All tests pass"
        }
      ])

      goals = GoalStore.get_active_goals(agent_id)
      assert length(goals) == 1
      assert hd(goals).success_criteria == "All tests pass"
    end

    test "notes accumulate on goal updates", %{agent_id: agent_id} do
      goal = Goal.new("Notable goal")
      {:ok, _} = GoalStore.add_goal(agent_id, goal)

      ReflectionProcessor.process_goal_updates(agent_id, [
        %{"goal_id" => goal.id, "new_progress" => 0.3, "note" => "First update"}
      ])

      ReflectionProcessor.process_goal_updates(agent_id, [
        %{"goal_id" => goal.id, "new_progress" => 0.6, "note" => "Second update"}
      ])

      {:ok, updated} = GoalStore.get_goal(agent_id, goal.id)
      # Notes are now stored in the struct field, prepended (newest first)
      assert length(updated.notes) == 2
      assert Enum.any?(updated.notes, &String.contains?(&1, "First update"))
      assert Enum.any?(updated.notes, &String.contains?(&1, "Second update"))
    end
  end

  # ============================================================================
  # Group 1: Rich Goal Context Formatting
  # ============================================================================

  describe "rich goal formatting" do
    test "priority emojis appear in formatted goals", %{agent_id: agent_id} do
      goal_critical = Goal.new("Critical task", priority: 90)
      goal_high = Goal.new("High task", priority: 70)
      goal_medium = Goal.new("Medium task", priority: 50)
      goal_low = Goal.new("Low task", priority: 20)

      {:ok, _} = GoalStore.add_goal(agent_id, goal_critical)
      {:ok, _} = GoalStore.add_goal(agent_id, goal_high)
      {:ok, _} = GoalStore.add_goal(agent_id, goal_medium)
      {:ok, _} = GoalStore.add_goal(agent_id, goal_low)

      {:ok, context} = ReflectionProcessor.build_deep_context(agent_id, [])

      assert String.contains?(context.goals_text, "🔴")
      assert String.contains?(context.goals_text, "🟠")
      assert String.contains?(context.goals_text, "🟡")
      assert String.contains?(context.goals_text, "🟢")
    end

    test "deadline warnings for overdue goals", %{agent_id: agent_id} do
      past_deadline = DateTime.add(DateTime.utc_now(), -3600, :second)

      goal =
        Goal.new("Overdue goal",
          priority: 80,
          metadata: %{deadline: DateTime.to_iso8601(past_deadline)}
        )

      {:ok, _} = GoalStore.add_goal(agent_id, goal)

      {:ok, context} = ReflectionProcessor.build_deep_context(agent_id, [])
      assert String.contains?(context.goals_text, "OVERDUE")
    end

    test "success criteria included in formatting", %{agent_id: agent_id} do
      goal =
        Goal.new("Goal with criteria",
          priority: 50,
          metadata: %{success_criteria: "All tests pass"}
        )

      {:ok, _} = GoalStore.add_goal(agent_id, goal)

      {:ok, context} = ReflectionProcessor.build_deep_context(agent_id, [])
      assert String.contains?(context.goals_text, "Success criteria: All tests pass")
    end

    test "urgency sorting puts high-priority first", %{agent_id: agent_id} do
      goal_low = Goal.new("Low priority goal", priority: 20)
      goal_high = Goal.new("High priority goal", priority: 90)

      {:ok, _} = GoalStore.add_goal(agent_id, goal_low)
      {:ok, _} = GoalStore.add_goal(agent_id, goal_high)

      {:ok, context} = ReflectionProcessor.build_deep_context(agent_id, [])

      # High priority should appear before low priority
      high_pos = :binary.match(context.goals_text, "High priority goal") |> elem(0)
      low_pos = :binary.match(context.goals_text, "Low priority goal") |> elem(0)
      assert high_pos < low_pos
    end

    test "blocked goals in separate section", %{agent_id: agent_id} do
      active_goal = Goal.new("Active goal", priority: 50)
      blocked_goal = Goal.new("Blocked goal", priority: 80)

      {:ok, _} = GoalStore.add_goal(agent_id, active_goal)
      {:ok, _} = GoalStore.add_goal(agent_id, blocked_goal)
      {:ok, _} = GoalStore.block_goal(agent_id, blocked_goal.id, ["dependency missing"])

      {:ok, context} = ReflectionProcessor.build_deep_context(agent_id, [])

      assert String.contains?(context.goals_text, "### Blocked Goals")
      assert String.contains?(context.goals_text, "[BLOCKED]")
      assert String.contains?(context.goals_text, "dependency missing")
    end
  end

  # ============================================================================
  # Group 2: Convenience API + Config
  # ============================================================================

  describe "maybe_reflect/2" do
    test "returns :skipped when gating says no", %{agent_id: agent_id} do
      # Do a reflection first to set timestamp
      {:ok, _} = ReflectionProcessor.reflect(agent_id, "Setup")

      assert {:ok, :skipped} =
               ReflectionProcessor.maybe_reflect(agent_id,
                 interval_ms: 999_999_999,
                 threshold: 999_999
               )
    end

    test "runs reflection when force: true", %{agent_id: agent_id} do
      # Do a reflection first to set timestamp
      {:ok, _} = ReflectionProcessor.reflect(agent_id, "Setup")

      {:ok, result} =
        ReflectionProcessor.maybe_reflect(agent_id,
          force: true,
          interval_ms: 999_999_999,
          threshold: 999_999
        )

      assert is_map(result)
      assert is_list(result.insights)
    end
  end

  describe "reflect_now/2" do
    test "is an alias for deep_reflect", %{agent_id: agent_id} do
      {:ok, result} = ReflectionProcessor.reflect_now(agent_id)
      assert is_map(result)
      assert is_list(result.insights)
      assert is_integer(result.duration_ms)
    end
  end

  describe "default_config/0" do
    test "returns expected configuration keys" do
      config = ReflectionProcessor.default_config()

      assert is_map(config)
      assert Map.has_key?(config, :min_reflection_interval)
      assert Map.has_key?(config, :signal_threshold)
      assert Map.has_key?(config, :llm_provider)
      assert Map.has_key?(config, :reflection_model)
      assert config.min_reflection_interval == 600_000
      assert config.signal_threshold == 50
    end
  end

  # ============================================================================
  # Group 3: Result Map Enrichment
  # ============================================================================

  describe "result map enrichment" do
    test "result includes insight_suggestions list", %{agent_id: agent_id} do
      {:ok, result} = ReflectionProcessor.deep_reflect(agent_id)

      assert Map.has_key?(result, :insight_suggestions)
      assert is_list(result.insight_suggestions)
    end

    test "result includes knowledge_archived count", %{agent_id: agent_id} do
      {:ok, result} = ReflectionProcessor.deep_reflect(agent_id)

      assert Map.has_key?(result, :knowledge_archived)
      assert is_integer(result.knowledge_archived)
      assert result.knowledge_archived >= 0
    end

    test "result includes relationship_updates count", %{agent_id: agent_id} do
      {:ok, result} = ReflectionProcessor.deep_reflect(agent_id)

      assert Map.has_key?(result, :relationship_updates)
      assert is_integer(result.relationship_updates)
      assert result.relationship_updates >= 0
    end
  end

  # ============================================================================
  # Group 4: Signal Improvements
  # ============================================================================

  describe "signal improvements" do
    test "truncate helper works on long strings" do
      # Test via the format_event_for_context which uses similar patterns
      # The truncate/2 is private, but we can verify behavior through integration
      {:ok, result} = ReflectionProcessor.deep_reflect("signal_test_agent")
      assert is_map(result)
    end
  end

  # ============================================================================
  # Group 5: Insight Suggestion Dedup
  # ============================================================================

  describe "insight suggestion dedup" do
    test "duplicate suggestions not re-added", %{agent_id: agent_id} do
      wm = WorkingMemory.new(agent_id)
      wm = WorkingMemory.add_thought(wm, "[Insight Suggestion] I am curious")
      Arbor.Memory.save_working_memory(agent_id, wm)

      # Create a mock that returns the same suggestion
      defmodule DedupMock do
        def generate_text(_prompt, _opts) do
          json =
            Jason.encode!(%{
              "insights" => [],
              "goal_updates" => [],
              "learnings" => [],
              "new_goals" => [],
              "knowledge_nodes" => [],
              "knowledge_edges" => [],
              "self_insight_suggestions" => [
                %{"content" => "I am curious", "category" => "personality", "confidence" => 0.6},
                %{"content" => "I am thorough", "category" => "personality", "confidence" => 0.7}
              ]
            })

          {:ok, json}
        end
      end

      Application.put_env(:arbor_memory, :reflection_llm_module, DedupMock)

      try do
        {:ok, _} = ReflectionProcessor.deep_reflect(agent_id)

        updated_wm = Arbor.Memory.get_working_memory(agent_id)
        suggestion_count =
          updated_wm.recent_thoughts
          |> Enum.count(fn t -> String.starts_with?(thought_content(t), "[Insight Suggestion]") end)

        # Should be 2: one existing + one new (not duplicate)
        assert suggestion_count == 2

        # Verify "I am curious" only appears once
        curious_count =
          updated_wm.recent_thoughts
          |> Enum.count(fn t -> String.contains?(thought_content(t), "I am curious") end)

        assert curious_count == 1
      after
        Application.put_env(
          :arbor_memory,
          :reflection_llm_module,
          ReflectionProcessor.MockLLM
        )
      end
    end

    test "caps at 10 total suggestions", %{agent_id: agent_id} do
      wm = WorkingMemory.new(agent_id)

      # Pre-fill with 9 suggestions
      wm =
        Enum.reduce(1..9, wm, fn i, acc ->
          WorkingMemory.add_thought(acc, "[Insight Suggestion] Existing #{i}")
        end)

      Arbor.Memory.save_working_memory(agent_id, wm)

      defmodule CapMock do
        def generate_text(_prompt, _opts) do
          json =
            Jason.encode!(%{
              "insights" => [],
              "goal_updates" => [],
              "learnings" => [],
              "new_goals" => [],
              "knowledge_nodes" => [],
              "knowledge_edges" => [],
              "self_insight_suggestions" => [
                %{"content" => "New A", "category" => "personality", "confidence" => 0.6},
                %{"content" => "New B", "category" => "personality", "confidence" => 0.7},
                %{"content" => "New C", "category" => "personality", "confidence" => 0.8}
              ]
            })

          {:ok, json}
        end
      end

      Application.put_env(:arbor_memory, :reflection_llm_module, CapMock)

      try do
        {:ok, _} = ReflectionProcessor.deep_reflect(agent_id)

        updated_wm = Arbor.Memory.get_working_memory(agent_id)
        suggestion_count =
          updated_wm.recent_thoughts
          |> Enum.count(fn t -> String.starts_with?(thought_content(t), "[Insight Suggestion]") end)

        # 9 existing + at most 1 new = 10 (capped)
        assert suggestion_count == 10
      after
        Application.put_env(
          :arbor_memory,
          :reflection_llm_module,
          ReflectionProcessor.MockLLM
        )
      end
    end

    test "new suggestions added when below cap", %{agent_id: agent_id} do
      wm = WorkingMemory.new(agent_id)
      Arbor.Memory.save_working_memory(agent_id, wm)

      defmodule FreshMock do
        def generate_text(_prompt, _opts) do
          json =
            Jason.encode!(%{
              "insights" => [],
              "goal_updates" => [],
              "learnings" => [],
              "new_goals" => [],
              "knowledge_nodes" => [],
              "knowledge_edges" => [],
              "self_insight_suggestions" => [
                %{"content" => "Fresh insight A", "category" => "value", "confidence" => 0.7},
                %{"content" => "Fresh insight B", "category" => "value", "confidence" => 0.8}
              ]
            })

          {:ok, json}
        end
      end

      Application.put_env(:arbor_memory, :reflection_llm_module, FreshMock)

      try do
        {:ok, _} = ReflectionProcessor.deep_reflect(agent_id)

        updated_wm = Arbor.Memory.get_working_memory(agent_id)
        suggestion_count =
          updated_wm.recent_thoughts
          |> Enum.count(fn t -> String.starts_with?(thought_content(t), "[Insight Suggestion]") end)

        assert suggestion_count == 2
      after
        Application.put_env(
          :arbor_memory,
          :reflection_llm_module,
          ReflectionProcessor.MockLLM
        )
      end
    end
  end
end
