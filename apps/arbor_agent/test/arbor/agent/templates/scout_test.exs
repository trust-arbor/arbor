defmodule Arbor.Agent.Templates.ScoutTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Agent.Character
  alias Arbor.Agent.Templates.Scout

  describe "Template behaviour implementation" do
    test "implements all required callbacks" do
      Code.ensure_loaded!(Scout)
      assert function_exported?(Scout, :character, 0)
      assert function_exported?(Scout, :trust_tier, 0)
      assert function_exported?(Scout, :initial_goals, 0)
      assert function_exported?(Scout, :required_capabilities, 0)
    end

    test "implements optional callbacks" do
      assert function_exported?(Scout, :description, 0)
      assert function_exported?(Scout, :nature, 0)
      assert function_exported?(Scout, :values, 0)
      assert function_exported?(Scout, :relationship_style, 0)
    end
  end

  describe "character/0" do
    test "returns a valid Character struct" do
      char = Scout.character()
      assert %Character{} = char
      assert char.name == "Scout"
    end

    test "has efficient and focused traits" do
      char = Scout.character()
      assert length(char.traits) == 2

      trait_names = Enum.map(char.traits, & &1.name)
      assert "efficient" in trait_names
      assert "focused" in trait_names

      efficient = Enum.find(char.traits, &(&1.name == "efficient"))
      assert efficient.intensity >= 0.9
    end

    test "values speed and accuracy" do
      char = Scout.character()
      assert "speed" in char.values
      assert "accuracy" in char.values
    end

    test "has concise tone and style" do
      char = Scout.character()
      assert char.tone == "concise"
      assert char.style =~ "Brief"
    end

    test "renders to valid system prompt" do
      prompt = Scout.character() |> Character.to_system_prompt()
      assert prompt =~ "# Character: Scout"
      assert prompt =~ "## Personality"
    end
  end

  describe "trust_tier/0" do
    test "returns :probationary" do
      assert Scout.trust_tier() == :probationary
    end
  end

  describe "required_capabilities/0" do
    test "has minimal capabilities" do
      caps = Scout.required_capabilities()
      assert length(caps) == 1

      resources = Enum.map(caps, & &1.resource)
      assert "arbor://orchestrator/execute" in resources
    end
  end

  describe "description/0" do
    test "returns a non-empty string mentioning reconnaissance" do
      desc = Scout.description()
      assert is_binary(desc)
      assert String.length(desc) > 20
      assert desc =~ "reconnaissance" or desc =~ "explorer"
    end
  end
end
