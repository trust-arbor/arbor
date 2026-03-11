defmodule Arbor.Agent.HeartbeatPromptTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Agent.HeartbeatPrompt

  # Minimal state that won't trigger external calls (safe_call rescues all errors)
  defp minimal_state(overrides \\ %{}) do
    Map.merge(
      %{
        id: "test_agent_001",
        agent_id: "test_agent_001",
        cognitive_mode: :consolidation,
        enabled_prompt_sections: :all,
        pending_messages: [],
        background_suggestions: [],
        context_window: nil
      },
      overrides
    )
  end

  describe "prompt_section_names/0" do
    test "returns list of 12 section names" do
      names = HeartbeatPrompt.prompt_section_names()
      assert length(names) == 12
      assert :timing in names
      assert :cognitive in names
      assert :goals in names
      assert :response_format in names
      assert :directive in names
      assert :tools in names
      assert :proposals in names
      assert :patterns in names
      assert :percepts in names
      assert :pending in names
      assert :self_knowledge in names
      assert :conversation in names
    end
  end

  describe "build_prompt/1" do
    test "returns a non-empty string with minimal state" do
      prompt = HeartbeatPrompt.build_prompt(minimal_state())
      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end

    test "includes timing section" do
      prompt = HeartbeatPrompt.build_prompt(minimal_state())
      # TimingContext.to_markdown always produces something with time info
      assert prompt =~ "Time" or prompt =~ "UTC" or prompt =~ ":"
    end

    test "includes cognitive section for non-conversation modes" do
      prompt = HeartbeatPrompt.build_prompt(minimal_state(%{cognitive_mode: :introspection}))
      assert prompt =~ "Introspection"
    end

    test "includes response format section" do
      prompt = HeartbeatPrompt.build_prompt(minimal_state())
      assert prompt =~ "Response Format"
      assert prompt =~ "valid JSON"
    end

    test "includes goals section" do
      prompt = HeartbeatPrompt.build_prompt(minimal_state())
      # Even with no active goals, the section appears
      assert prompt =~ "Active Goals" or prompt =~ "goals"
    end

    test "includes tools section" do
      prompt = HeartbeatPrompt.build_prompt(minimal_state())
      assert prompt =~ "Available Actions" or prompt =~ "actions"
    end
  end

  describe "build_prompt/1 section filtering" do
    test "filters to only specified sections" do
      state = minimal_state(%{enabled_prompt_sections: [:response_format]})
      prompt = HeartbeatPrompt.build_prompt(state)
      assert prompt =~ "Response Format"
      # Should NOT have timing section
      refute prompt =~ "Active Goals"
    end

    test "empty section list returns empty string" do
      state = minimal_state(%{enabled_prompt_sections: []})
      prompt = HeartbeatPrompt.build_prompt(state)
      assert prompt == ""
    end

    test ":all includes all sections" do
      state = minimal_state(%{enabled_prompt_sections: :all})
      prompt = HeartbeatPrompt.build_prompt(state)
      assert prompt =~ "Response Format"
      assert prompt =~ "Available Actions"
    end
  end

  describe "build_prompt/1 pending messages" do
    test "includes pending messages section when messages exist" do
      state =
        minimal_state(%{
          enabled_prompt_sections: [:pending],
          pending_messages: [
            %{content: "Hello agent!", timestamp: DateTime.utc_now()}
          ]
        })

      prompt = HeartbeatPrompt.build_prompt(state)
      assert prompt =~ "Pending Messages"
      assert prompt =~ "Hello agent!"
    end

    test "omits pending section when no messages" do
      state = minimal_state(%{enabled_prompt_sections: [:pending], pending_messages: []})
      prompt = HeartbeatPrompt.build_prompt(state)
      # pending_section returns nil when empty, gets filtered out
      assert prompt == ""
    end
  end

  describe "build_prompt/1 patterns section" do
    test "includes patterns when background_suggestions has learning items" do
      state =
        minimal_state(%{
          enabled_prompt_sections: [:patterns],
          background_suggestions: [
            %{type: :learning, content: "You tend to read files before editing", confidence: 0.85}
          ]
        })

      prompt = HeartbeatPrompt.build_prompt(state)
      assert prompt =~ "Detected Action Patterns"
      assert prompt =~ "read files before editing"
      assert prompt =~ "85%"
    end

    test "omits patterns when no learning suggestions" do
      state = minimal_state(%{enabled_prompt_sections: [:patterns], background_suggestions: []})
      prompt = HeartbeatPrompt.build_prompt(state)
      assert prompt == ""
    end

    test "filters non-learning suggestions" do
      state =
        minimal_state(%{
          enabled_prompt_sections: [:patterns],
          background_suggestions: [%{type: :other, content: "not a learning"}]
        })

      prompt = HeartbeatPrompt.build_prompt(state)
      assert prompt == ""
    end
  end

  describe "build_prompt/1 conversation section" do
    test "omits conversation section when context_window is nil" do
      state = minimal_state(%{enabled_prompt_sections: [:conversation], context_window: nil})
      prompt = HeartbeatPrompt.build_prompt(state)
      assert prompt == ""
    end
  end

  describe "build_prompt/1 directive section" do
    test "goal_pursuit mode directive" do
      state =
        minimal_state(%{enabled_prompt_sections: [:directive], cognitive_mode: :goal_pursuit})

      prompt = HeartbeatPrompt.build_prompt(state)
      assert prompt =~ "active goals"
      assert prompt =~ "concrete progress"
    end

    test "plan_execution mode directive" do
      state =
        minimal_state(%{enabled_prompt_sections: [:directive], cognitive_mode: :plan_execution})

      prompt = HeartbeatPrompt.build_prompt(state)
      assert prompt =~ "plan execution"
      assert prompt =~ "Decompose"
    end

    test "conversation mode directive returns nothing" do
      state =
        minimal_state(%{enabled_prompt_sections: [:directive], cognitive_mode: :conversation})

      prompt = HeartbeatPrompt.build_prompt(state)
      assert prompt == ""
    end
  end

  describe "system_prompt/1" do
    test "returns system prompt with format instructions" do
      prompt = HeartbeatPrompt.system_prompt(%{})
      assert prompt =~ "autonomous AI agent"
      assert prompt =~ "valid JSON"
      assert prompt =~ "thinking"
      assert prompt =~ "actions"
      assert prompt =~ "memory_notes"
      assert prompt =~ "goal_updates"
      assert prompt =~ "proposal_decisions"
      assert prompt =~ "decompositions"
      assert prompt =~ "identity_insights"
    end

    test "includes nonce preamble when nonce is provided" do
      prompt = HeartbeatPrompt.system_prompt(%{nonce: "test_nonce_123"})
      assert prompt =~ "test_nonce_123" or prompt =~ "data"
    end

    test "omits nonce preamble when no nonce" do
      prompt = HeartbeatPrompt.system_prompt(%{})
      # Should not have the data-tag preamble
      refute prompt =~ "data_"
    end
  end
end
