defmodule Arbor.Memory.Reflection.PromptBuilderTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Memory.Reflection.PromptBuilder

  # --- Type Conversions ---

  describe "atomize_priority_to_int/1" do
    test "critical → 90" do
      assert PromptBuilder.atomize_priority_to_int("critical") == 90
    end

    test "high → 70" do
      assert PromptBuilder.atomize_priority_to_int("high") == 70
    end

    test "medium → 50" do
      assert PromptBuilder.atomize_priority_to_int("medium") == 50
    end

    test "low → 30" do
      assert PromptBuilder.atomize_priority_to_int("low") == 30
    end

    test "nil → 50 (default)" do
      assert PromptBuilder.atomize_priority_to_int(nil) == 50
    end

    test "unknown string → 50 (default)" do
      assert PromptBuilder.atomize_priority_to_int("urgent") == 50
    end
  end

  describe "atomize_type/1" do
    test "achieve → :achieve" do
      assert PromptBuilder.atomize_type("achieve") == :achieve
    end

    test "achievement → :achieve" do
      assert PromptBuilder.atomize_type("achievement") == :achieve
    end

    test "maintain → :maintain" do
      assert PromptBuilder.atomize_type("maintain") == :maintain
    end

    test "maintenance → :maintain" do
      assert PromptBuilder.atomize_type("maintenance") == :maintain
    end

    test "explore → :explore" do
      assert PromptBuilder.atomize_type("explore") == :explore
    end

    test "exploration → :explore" do
      assert PromptBuilder.atomize_type("exploration") == :explore
    end

    test "learn → :learn" do
      assert PromptBuilder.atomize_type("learn") == :learn
    end

    test "nil → :achieve (default)" do
      assert PromptBuilder.atomize_type(nil) == :achieve
    end

    test "unknown → :achieve (default)" do
      assert PromptBuilder.atomize_type("research") == :achieve
    end
  end

  describe "safe_node_type/1" do
    test "person → :relationship" do
      assert PromptBuilder.safe_node_type("person") == :relationship
    end

    test "project → :experience" do
      assert PromptBuilder.safe_node_type("project") == :experience
    end

    test "concept → :fact" do
      assert PromptBuilder.safe_node_type("concept") == :fact
    end

    test "tool → :skill" do
      assert PromptBuilder.safe_node_type("tool") == :skill
    end

    test "goal → :insight" do
      assert PromptBuilder.safe_node_type("goal") == :insight
    end

    test "nil → :concept" do
      assert PromptBuilder.safe_node_type(nil) == :concept
    end

    test "unknown → :fact" do
      assert PromptBuilder.safe_node_type("other") == :fact
    end
  end

  describe "priority_emoji/1" do
    test "critical priority (>=80)" do
      assert PromptBuilder.priority_emoji(90) == "🔴"
      assert PromptBuilder.priority_emoji(80) == "🔴"
    end

    test "high priority (>=60)" do
      assert PromptBuilder.priority_emoji(70) == "🟠"
      assert PromptBuilder.priority_emoji(60) == "🟠"
    end

    test "medium priority (>=40)" do
      assert PromptBuilder.priority_emoji(50) == "🟡"
      assert PromptBuilder.priority_emoji(40) == "🟡"
    end

    test "low priority (<40)" do
      assert PromptBuilder.priority_emoji(30) == "🟢"
      assert PromptBuilder.priority_emoji(10) == "🟢"
    end

    test "non-integer returns default" do
      assert PromptBuilder.priority_emoji("high") == "🟡"
    end
  end

  # --- Goal Formatting ---

  describe "format_goals_for_prompt/1" do
    test "empty list returns no active goals message" do
      assert PromptBuilder.format_goals_for_prompt([]) == "(No active goals)"
    end

    test "formats single active goal" do
      goal = make_goal(%{description: "Test goal", priority: 70, progress: 0.5})
      result = PromptBuilder.format_goals_for_prompt([goal])
      assert result =~ "Test goal"
      assert result =~ "50"
      assert result =~ "Priority: 70"
    end

    test "separates blocked goals" do
      active = make_goal(%{description: "Active goal", status: :active, priority: 50})
      blocked = make_goal(%{description: "Blocked goal", status: :blocked, priority: 70})
      result = PromptBuilder.format_goals_for_prompt([active, blocked])
      assert result =~ "Active goal"
      assert result =~ "Blocked Goals"
      assert result =~ "Blocked goal"
    end

    test "sorts active goals by urgency (priority)" do
      low = make_goal(%{description: "Low", priority: 30, progress: 0.0})
      high = make_goal(%{description: "High", priority: 90, progress: 0.0})
      result = PromptBuilder.format_goals_for_prompt([low, high])
      high_pos = :binary.match(result, "High") |> elem(0)
      low_pos = :binary.match(result, "Low") |> elem(0)
      assert high_pos < low_pos
    end
  end

  describe "format_single_goal/1" do
    test "includes goal id and description" do
      goal = make_goal(%{id: "goal_123", description: "Build feature"})
      result = PromptBuilder.format_single_goal(goal)
      assert result =~ "goal_123"
      assert result =~ "Build feature"
    end

    test "shows progress bar and percentage" do
      goal = make_goal(%{progress: 0.75})
      result = PromptBuilder.format_single_goal(goal)
      assert result =~ "75"
      assert result =~ "█"
    end

    test "includes success criteria when present" do
      goal = make_goal(%{success_criteria: "All tests pass"})
      result = PromptBuilder.format_single_goal(goal)
      assert result =~ "All tests pass"
    end

    test "includes notes when present" do
      goal = make_goal(%{notes: ["Note 1", "Note 2"]})
      result = PromptBuilder.format_single_goal(goal)
      assert result =~ "Note 1"
      assert result =~ "Note 2"
    end
  end

  describe "format_blocked_goal/1" do
    test "includes BLOCKED label" do
      goal = make_goal(%{description: "Stuck", status: :blocked})
      result = PromptBuilder.format_blocked_goal(goal)
      assert result =~ "[BLOCKED]"
      assert result =~ "Stuck"
    end

    test "shows blockers when present" do
      goal = make_goal(%{status: :blocked, metadata: %{blockers: ["API down", "Waiting on review"]}})
      result = PromptBuilder.format_blocked_goal(goal)
      assert result =~ "API down"
      assert result =~ "Waiting on review"
    end
  end

  describe "format_self_knowledge/1" do
    test "returns placeholder for empty self-knowledge" do
      sk = %{capabilities: [], personality_traits: [], values: []}
      result = PromptBuilder.format_self_knowledge(sk)
      assert result =~ "no entries yet"
    end

    test "formats capabilities" do
      sk = %{
        capabilities: [%{name: "coding", proficiency: 0.85}],
        personality_traits: [],
        values: []
      }

      result = PromptBuilder.format_self_knowledge(sk)
      assert result =~ "Capabilities"
      assert result =~ "coding"
      assert result =~ "85"
    end

    test "formats personality traits" do
      sk = %{
        capabilities: [],
        personality_traits: [%{trait: "curious", strength: 0.9}],
        values: []
      }

      result = PromptBuilder.format_self_knowledge(sk)
      assert result =~ "Personality Traits"
      assert result =~ "curious"
      assert result =~ "90"
    end

    test "formats values" do
      sk = %{
        capabilities: [],
        personality_traits: [],
        values: [%{value: "honesty", importance: 0.95}]
      }

      result = PromptBuilder.format_self_knowledge(sk)
      assert result =~ "Values"
      assert result =~ "honesty"
      assert result =~ "95"
    end
  end

  describe "build_reflection_prompt/1" do
    test "builds complete prompt with all context sections" do
      context = %{
        self_knowledge_text: "I am an AI",
        goals_text: "Goal 1: Build tests",
        knowledge_graph_text: "Node: Arbor",
        working_memory_text: "Current focus: testing",
        recent_thinking_text: "Reflected on patterns",
        recent_activity_text: "Wrote 50 tests"
      }

      result = PromptBuilder.build_reflection_prompt(context)
      assert result =~ "deep reflection"
      assert result =~ "EVALUATE PROGRESS"
      assert result =~ "goal_updates"
      assert result =~ "JSON format"
    end
  end

  # --- Helpers ---

  defp make_goal(attrs) do
    defaults = %{
      id: "goal_#{:rand.uniform(1000)}",
      description: "Default goal",
      priority: 50,
      type: :achieve,
      status: :active,
      progress: 0.0,
      deadline: nil,
      success_criteria: nil,
      notes: [],
      metadata: %{},
      parent_id: nil
    }

    Map.merge(defaults, attrs)
  end
end
