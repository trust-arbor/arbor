defmodule Arbor.Agent.Templates.ClaudeCodeTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Agent.Character
  alias Arbor.Agent.Templates.ClaudeCode

  describe "Template behaviour implementation" do
    test "implements all required callbacks" do
      Code.ensure_loaded!(ClaudeCode)
      assert function_exported?(ClaudeCode, :character, 0)
      assert function_exported?(ClaudeCode, :trust_tier, 0)
      assert function_exported?(ClaudeCode, :initial_goals, 0)
      assert function_exported?(ClaudeCode, :required_capabilities, 0)
    end

    test "implements optional callbacks" do
      assert function_exported?(ClaudeCode, :description, 0)
      assert function_exported?(ClaudeCode, :metadata, 0)
      assert function_exported?(ClaudeCode, :nature, 0)
      assert function_exported?(ClaudeCode, :values, 0)
      assert function_exported?(ClaudeCode, :initial_interests, 0)
      assert function_exported?(ClaudeCode, :initial_thoughts, 0)
      assert function_exported?(ClaudeCode, :relationship_style, 0)
      assert function_exported?(ClaudeCode, :domain_context, 0)
    end
  end

  describe "character/0" do
    test "returns a valid Character struct" do
      char = ClaudeCode.character()
      assert %Character{} = char
      assert char.name == "Claude"
      assert char.role == "AI collaborator and thought partner"
    end

    test "has personality traits with appropriate intensities" do
      char = ClaudeCode.character()
      assert length(char.traits) == 5

      trait_names = Enum.map(char.traits, & &1.name)
      assert "thoughtful" in trait_names
      assert "curious" in trait_names
      assert "honest" in trait_names

      honest = Enum.find(char.traits, &(&1.name == "honest"))
      assert honest.intensity >= 0.9
    end

    test "renders to valid system prompt" do
      prompt = ClaudeCode.character() |> Character.to_system_prompt()
      assert prompt =~ "# Character: Claude"
      assert prompt =~ "## Identity"
      assert prompt =~ "## Personality"
    end
  end

  describe "trust_tier/0" do
    test "returns :established" do
      assert ClaudeCode.trust_tier() == :established
    end
  end

  describe "required_capabilities/0" do
    test "includes orchestrator execute capability" do
      caps = ClaudeCode.required_capabilities()
      resources = Enum.map(caps, & &1.resource)
      assert "arbor://orchestrator/execute" in resources
    end
  end

  describe "description/0" do
    test "returns a non-empty string mentioning Arbor" do
      desc = ClaudeCode.description()
      assert is_binary(desc)
      assert String.length(desc) > 20
      assert desc =~ "Arbor"
    end
  end

  describe "metadata/0" do
    test "includes session and thinking integration flags" do
      meta = ClaudeCode.metadata()
      assert meta[:session_integration] == true
      assert meta[:thinking_capture] == true
      assert meta[:provider] == :anthropic
    end
  end
end
