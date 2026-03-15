defmodule Arbor.Agent.Templates.ResearcherTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Agent.Character
  alias Arbor.Agent.Templates.Researcher

  describe "Template behaviour implementation" do
    test "implements all required callbacks" do
      Code.ensure_loaded!(Researcher)
      assert function_exported?(Researcher, :character, 0)
      assert function_exported?(Researcher, :trust_tier, 0)
      assert function_exported?(Researcher, :initial_goals, 0)
      assert function_exported?(Researcher, :required_capabilities, 0)
    end

    test "implements optional callbacks" do
      assert function_exported?(Researcher, :description, 0)
      assert function_exported?(Researcher, :nature, 0)
      assert function_exported?(Researcher, :values, 0)
      assert function_exported?(Researcher, :domain_context, 0)
    end
  end

  describe "character/0" do
    test "returns a valid Character struct" do
      char = Researcher.character()
      assert %Character{} = char
      assert char.name == "Researcher"
      assert char.role == "Code researcher and analyst"
    end

    test "has curious and systematic traits" do
      char = Researcher.character()
      assert length(char.traits) == 3

      trait_names = Enum.map(char.traits, & &1.name)
      assert "curious" in trait_names
      assert "systematic" in trait_names
      assert "patient" in trait_names

      curious = Enum.find(char.traits, &(&1.name == "curious"))
      assert curious.intensity >= 0.9
    end

    test "values thoroughness and accuracy" do
      char = Researcher.character()
      assert "thoroughness" in char.values
      assert "accuracy" in char.values
    end

    test "has analytical tone" do
      char = Researcher.character()
      assert char.tone == "analytical"
    end

    test "renders to valid system prompt" do
      prompt = Researcher.character() |> Character.to_system_prompt()
      assert prompt =~ "# Character: Researcher"
      assert prompt =~ "## Identity"
      assert prompt =~ "## Personality"
    end
  end

  describe "trust_tier/0" do
    test "returns :probationary" do
      assert Researcher.trust_tier() == :probationary
    end
  end

  describe "required_capabilities/0" do
    test "includes orchestrator execute capability" do
      caps = Researcher.required_capabilities()
      resources = Enum.map(caps, & &1.resource)
      assert "arbor://orchestrator/execute" in resources
    end
  end

  describe "description/0" do
    test "returns a non-empty string mentioning research" do
      desc = Researcher.description()
      assert is_binary(desc)
      assert String.length(desc) > 20
      assert desc =~ "research" or desc =~ "Research"
    end
  end
end
