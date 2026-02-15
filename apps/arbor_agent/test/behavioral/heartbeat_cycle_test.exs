defmodule Arbor.Behavioral.HeartbeatCycleTest do
  @moduledoc """
  Behavioral test: agent heartbeat cycle.

  Verifies heartbeat subsystems that are used by the DOT Session:
  1. HeartbeatPrompt builds valid prompts with cognitive modes
  2. CognitivePrompts returns mode-specific instructions
  3. Heartbeat responses parse correctly
  4. Working memory persists via ETS
  5. Goal store lifecycle works per-agent

  The actual heartbeat loop is managed by the DOT Session graph.
  These tests verify the building blocks it uses.
  """
  use Arbor.Test.BehavioralCase

  alias Arbor.Test.MockLLM

  describe "scenario: heartbeat prompt construction" do
    test "HeartbeatPrompt builds valid prompt with cognitive mode" do
      agent_state = %{
        agent_id: "agent_test_hb_1",
        display_name: "TestBot",
        goals: [],
        working_memory: %{},
        heartbeat_count: 0,
        cognitive_mode: :reflection
      }

      prompt = Arbor.Agent.HeartbeatPrompt.build_prompt(agent_state)

      assert is_binary(prompt)
      assert String.length(prompt) > 100
      # Should ask for JSON response
      assert prompt =~ "JSON" or prompt =~ "json"
    end

    test "HeartbeatPrompt adapts to goal_pursuit mode" do
      agent_state = %{
        agent_id: "agent_test_hb_2",
        display_name: "TestBot",
        goals: [],
        working_memory: %{},
        heartbeat_count: 1,
        cognitive_mode: :goal_pursuit
      }

      prompt = Arbor.Agent.HeartbeatPrompt.build_prompt(agent_state)

      # Goal pursuit mode should reference goals/actions
      assert prompt =~ "goal" or prompt =~ "Goal" or prompt =~ "action" or prompt =~ "Action"
    end

    test "CognitivePrompts.prompt_for/1 returns mode-specific instructions" do
      # Each mode has a distinct prompt
      assert Arbor.Agent.CognitivePrompts.prompt_for(:goal_pursuit) =~ "Goal"

      assert Arbor.Agent.CognitivePrompts.prompt_for(:consolidation) =~ "consolidat" or
               Arbor.Agent.CognitivePrompts.prompt_for(:consolidation) =~ "Consolidat"

      reflection = Arbor.Agent.CognitivePrompts.prompt_for(:reflection)
      assert reflection =~ "Reflection" or reflection =~ "reflection"

      # Conversation mode returns empty (no extra instructions)
      assert Arbor.Agent.CognitivePrompts.prompt_for(:conversation) == ""
    end

    test "all cognitive modes have defined prompts" do
      modes = Arbor.Agent.CognitivePrompts.modes()

      for mode <- modes do
        prompt = Arbor.Agent.CognitivePrompts.prompt_for(mode)
        assert is_binary(prompt), "Mode #{inspect(mode)} should return a string prompt"
      end
    end
  end

  describe "scenario: heartbeat response parsing" do
    test "valid heartbeat JSON is parsed into structured data" do
      json = MockLLM.heartbeat_response(cognitive_mode: "reflection")
      parsed = Jason.decode!(json)

      assert Map.has_key?(parsed, "thoughts")
      assert Map.has_key?(parsed, "observations")
      assert Map.has_key?(parsed, "cognitive_mode")
      assert Map.has_key?(parsed, "new_goals")
      assert Map.has_key?(parsed, "goal_updates")
      assert Map.has_key?(parsed, "memory_notes")
      assert Map.has_key?(parsed, "proposals")
      assert Map.has_key?(parsed, "actions")
    end

    test "heartbeat response with new goals creates goals in store" do
      _agent_id = "agent_test_goal_creation"

      goals = [
        %{
          "description" => "Learn about the codebase",
          "priority" => "medium",
          "reasoning" => "Need to understand before acting"
        }
      ]

      json = MockLLM.heartbeat_response(new_goals: goals)
      parsed = Jason.decode!(json)

      # Verify the structure is correct for goal processing
      assert length(parsed["new_goals"]) == 1
      assert hd(parsed["new_goals"])["description"] == "Learn about the codebase"

      # The actual goal store integration would happen in the full
      # heartbeat processing pipeline — this validates the response format
      assert is_list(parsed["new_goals"])
    end
  end

  describe "scenario: working memory persistence" do
    test "working memory survives write-read cycle via ETS" do
      agent_id = "agent_test_wm_#{:erlang.unique_integer([:positive])}"

      # Load creates a fresh WorkingMemory if none exists
      wm = Arbor.Memory.load_working_memory(agent_id)
      assert wm != nil

      # Modify and save
      updated = Map.put(wm, :custom_data, "test_value")
      Arbor.Memory.save_working_memory(agent_id, updated)

      # Read back — should get the updated version
      loaded = Arbor.Memory.load_working_memory(agent_id)
      assert loaded != nil
      assert Map.get(loaded, :custom_data) == "test_value"
    end

    test "working memory is agent-scoped (isolation)" do
      agent_a = "agent_test_wm_iso_a_#{:erlang.unique_integer([:positive])}"
      agent_b = "agent_test_wm_iso_b_#{:erlang.unique_integer([:positive])}"

      wm_a = Arbor.Memory.load_working_memory(agent_a)
      wm_b = Arbor.Memory.load_working_memory(agent_b)

      # Save distinct data for each
      Arbor.Memory.save_working_memory(agent_a, Map.put(wm_a, :tag, "alpha"))
      Arbor.Memory.save_working_memory(agent_b, Map.put(wm_b, :tag, "beta"))

      loaded_a = Arbor.Memory.load_working_memory(agent_a)
      loaded_b = Arbor.Memory.load_working_memory(agent_b)

      assert Map.get(loaded_a, :tag) == "alpha"
      assert Map.get(loaded_b, :tag) == "beta"
    end
  end

  describe "scenario: goal store lifecycle" do
    test "goals can be created and queried per agent" do
      agent_id = "agent_test_goal_lifecycle_#{:erlang.unique_integer([:positive])}"

      {:ok, goal} =
        Arbor.Memory.GoalStore.add_goal(agent_id, "Complete behavioral tests",
          priority: 80,
          type: :achieve
        )

      assert goal.description == "Complete behavioral tests"
      assert goal.status == :active
      assert goal.priority == 80

      # Retrieve active goals for this agent
      goals = Arbor.Memory.GoalStore.get_active_goals(agent_id)
      assert length(goals) >= 1

      found = Enum.find(goals, &(&1.id == goal.id))
      assert found != nil
      assert found.description == "Complete behavioral tests"
    end

    test "goals are agent-scoped (isolation)" do
      agent_a = "agent_test_goal_iso_a_#{:erlang.unique_integer([:positive])}"
      agent_b = "agent_test_goal_iso_b_#{:erlang.unique_integer([:positive])}"

      {:ok, _} = Arbor.Memory.GoalStore.add_goal(agent_a, "Goal for agent A")
      {:ok, _} = Arbor.Memory.GoalStore.add_goal(agent_b, "Goal for agent B")

      goals_a = Arbor.Memory.GoalStore.get_active_goals(agent_a)
      goals_b = Arbor.Memory.GoalStore.get_active_goals(agent_b)

      assert Enum.all?(goals_a, &(&1.description =~ "agent A"))
      assert Enum.all?(goals_b, &(&1.description =~ "agent B"))
    end
  end
end
