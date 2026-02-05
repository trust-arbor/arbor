defmodule Arbor.Agent.TemplateTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.Character
  alias Arbor.Agent.Templates.{CodeReviewer, Researcher, Scout}

  describe "Researcher template" do
    test "implements Template behaviour" do
      Code.ensure_loaded!(Researcher)
      assert function_exported?(Researcher, :character, 0)
      assert function_exported?(Researcher, :trust_tier, 0)
      assert function_exported?(Researcher, :initial_goals, 0)
      assert function_exported?(Researcher, :required_capabilities, 0)
      assert function_exported?(Researcher, :description, 0)
    end

    test "character returns a valid Character struct" do
      char = Researcher.character()
      assert %Character{} = char
      assert char.name == "Researcher"
      assert char.role == "Code researcher and analyst"
      assert length(char.traits) == 3
      assert "thoroughness" in char.values
      assert char.tone == "analytical"
      assert length(char.knowledge) == 2
      assert length(char.instructions) == 3
    end

    test "trust_tier is probationary" do
      assert Researcher.trust_tier() == :probationary
    end

    test "initial_goals are well-formed" do
      goals = Researcher.initial_goals()
      assert length(goals) == 2
      assert Enum.all?(goals, &is_map/1)
      assert Enum.all?(goals, &Map.has_key?(&1, :type))
      assert Enum.all?(goals, &Map.has_key?(&1, :description))
    end

    test "required_capabilities include read access and memory" do
      caps = Researcher.required_capabilities()
      assert length(caps) == 3
      resources = Enum.map(caps, & &1.resource)
      assert "arbor://fs/read/**" in resources
      assert "arbor://memory/**" in resources
      assert "arbor://shell/safe" in resources
    end

    test "character renders to valid system prompt" do
      prompt = Researcher.character() |> Character.to_system_prompt()
      assert prompt =~ "# Character: Researcher"
      assert prompt =~ "## Identity"
      assert prompt =~ "## Personality"
    end
  end

  describe "CodeReviewer template" do
    test "implements Template behaviour" do
      Code.ensure_loaded!(CodeReviewer)
      assert function_exported?(CodeReviewer, :character, 0)
      assert function_exported?(CodeReviewer, :trust_tier, 0)
      assert function_exported?(CodeReviewer, :initial_goals, 0)
      assert function_exported?(CodeReviewer, :required_capabilities, 0)
    end

    test "character has security-focused values" do
      char = CodeReviewer.character()
      assert char.name == "Code Reviewer"
      assert char.role == "Security-conscious code reviewer"
      assert "security" in char.values
      assert "correctness" in char.values
      assert char.tone == "constructive"
    end

    test "instructions include OWASP check" do
      char = CodeReviewer.character()
      assert Enum.any?(char.instructions, &String.contains?(&1, "OWASP"))
    end

    test "trust_tier is probationary" do
      assert CodeReviewer.trust_tier() == :probationary
    end
  end

  describe "Scout template" do
    test "implements Template behaviour" do
      Code.ensure_loaded!(Scout)
      assert function_exported?(Scout, :character, 0)
      assert function_exported?(Scout, :trust_tier, 0)
      assert function_exported?(Scout, :initial_goals, 0)
      assert function_exported?(Scout, :required_capabilities, 0)
    end

    test "character is minimal and fast" do
      char = Scout.character()
      assert char.name == "Scout"
      assert char.tone == "concise"
      assert char.style =~ "fluff"
      assert length(char.traits) == 2
    end

    test "has minimal capabilities (read-only)" do
      caps = Scout.required_capabilities()
      assert length(caps) == 1
      assert hd(caps).resource == "arbor://fs/read/**"
    end

    test "single exploration goal" do
      goals = Scout.initial_goals()
      assert length(goals) == 1
      assert hd(goals).type == :explore
    end
  end
end
