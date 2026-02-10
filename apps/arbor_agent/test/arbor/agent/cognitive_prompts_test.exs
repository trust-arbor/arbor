defmodule Arbor.Agent.CognitivePromptsTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.CognitivePrompts

  describe "prompt_for/1" do
    test "returns empty for :conversation" do
      assert CognitivePrompts.prompt_for(:conversation) == ""
    end

    test "returns introspection prompt" do
      prompt = CognitivePrompts.prompt_for(:introspection)
      assert prompt =~ "Introspection"
      assert prompt =~ "self-reflection"
      assert prompt =~ "genuine"
    end

    test "returns consolidation prompt" do
      prompt = CognitivePrompts.prompt_for(:consolidation)
      assert prompt =~ "Knowledge Consolidation"
      assert prompt =~ "organizing"
    end

    test "returns pattern_analysis prompt" do
      prompt = CognitivePrompts.prompt_for(:pattern_analysis)
      assert prompt =~ "Pattern Analysis"
      assert prompt =~ "Recurring sequences"
    end

    test "returns reflection prompt" do
      prompt = CognitivePrompts.prompt_for(:reflection)
      assert prompt =~ "Reflection"
      assert prompt =~ "experience"
    end

    test "returns insight_detection prompt" do
      prompt = CognitivePrompts.prompt_for(:insight_detection)
      assert prompt =~ "Insight Detection"
      assert prompt =~ "emergent understanding"
    end

    test "returns non-empty prompts for all non-conversation modes" do
      for mode <- CognitivePrompts.modes() -- [:conversation] do
        prompt = CognitivePrompts.prompt_for(mode)
        assert is_binary(prompt)
        assert String.length(prompt) > 0, "prompt for #{mode} should not be empty"
      end
    end
  end

  describe "model_for/1" do
    test "returns nil when no override configured" do
      assert CognitivePrompts.model_for(:conversation) == nil
      assert CognitivePrompts.model_for(:introspection) == nil
    end

    test "returns configured model override" do
      # The config.exs sets consolidation: "haiku"
      assert CognitivePrompts.model_for(:consolidation) == "haiku"
    end
  end

  describe "modes/0" do
    test "lists all cognitive modes" do
      modes = CognitivePrompts.modes()
      assert :conversation in modes
      assert :goal_pursuit in modes
      assert :plan_execution in modes
      assert :introspection in modes
      assert :consolidation in modes
      assert :pattern_analysis in modes
      assert :reflection in modes
      assert :insight_detection in modes
      assert length(modes) == 8
    end
  end
end
