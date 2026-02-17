defmodule Arbor.Orchestrator.Authoring.SystemPromptTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Authoring.SystemPrompt

  @modes [:blank, :idea, :file, :evolve, :template]

  describe "for_mode/1" do
    test "returns a string for each mode" do
      for mode <- @modes do
        prompt = SystemPrompt.for_mode(mode)
        assert is_binary(prompt), "Expected string for mode #{mode}"
        assert String.length(prompt) > 100, "Prompt too short for mode #{mode}"
      end
    end

    test "all modes include base context" do
      for mode <- @modes do
        prompt = SystemPrompt.for_mode(mode)
        assert prompt =~ "pipeline architect"
        assert prompt =~ "digraph"
        assert prompt =~ "PIPELINE_SPEC"
      end
    end

    test "all modes include handler registry" do
      for mode <- @modes do
        prompt = SystemPrompt.for_mode(mode)
        assert prompt =~ "Mdiamond"
        assert prompt =~ "shape="
      end
    end

    test "blank mode mentions interview" do
      prompt = SystemPrompt.for_mode(:blank)
      assert prompt =~ "scratch"
      assert prompt =~ "Ask questions"
    end

    test "idea mode is proactive" do
      prompt = SystemPrompt.for_mode(:idea)
      assert prompt =~ "proactive"
      assert prompt =~ "draft pipeline"
    end

    test "file mode focuses on extraction" do
      prompt = SystemPrompt.for_mode(:file)
      assert prompt =~ "extraction"
      assert prompt =~ "document"
    end

    test "evolve mode suggests improvements" do
      prompt = SystemPrompt.for_mode(:evolve)
      assert prompt =~ "improve"
      assert prompt =~ "existing pipeline"
    end

    test "template mode customizes" do
      prompt = SystemPrompt.for_mode(:template)
      assert prompt =~ "template"
      assert prompt =~ "customize"
    end

    test "includes all essential handler types" do
      prompt = SystemPrompt.for_mode(:blank)
      for type <- ["start", "exit", "codergen", "conditional", "parallel"] do
        assert prompt =~ type, "Missing handler type: #{type}"
      end
    end

    test "includes node attributes" do
      prompt = SystemPrompt.for_mode(:blank)
      for attr <- ["prompt", "max_retries", "goal_gate", "fidelity", "fan_out"] do
        assert prompt =~ attr, "Missing node attribute: #{attr}"
      end
    end
  end
end
