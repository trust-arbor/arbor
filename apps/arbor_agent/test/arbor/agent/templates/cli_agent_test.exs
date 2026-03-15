defmodule Arbor.Agent.Templates.CliAgentTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Agent.Character
  alias Arbor.Agent.Templates.CliAgent

  describe "Template behaviour implementation" do
    test "implements all required callbacks" do
      Code.ensure_loaded!(CliAgent)
      assert function_exported?(CliAgent, :character, 0)
      assert function_exported?(CliAgent, :trust_tier, 0)
      assert function_exported?(CliAgent, :initial_goals, 0)
      assert function_exported?(CliAgent, :required_capabilities, 0)
    end

    test "implements optional callbacks" do
      assert function_exported?(CliAgent, :description, 0)
      assert function_exported?(CliAgent, :metadata, 0)
      assert function_exported?(CliAgent, :nature, 0)
      assert function_exported?(CliAgent, :values, 0)
    end
  end

  describe "character/0" do
    test "returns a valid Character struct" do
      char = CliAgent.character()
      assert %Character{} = char
      assert char.name == "CLI Agent"
      assert char.role == "Interactive development agent"
    end

    test "has personality traits" do
      char = CliAgent.character()
      assert length(char.traits) == 4

      trait_names = Enum.map(char.traits, & &1.name)
      assert "thorough" in trait_names
      assert "responsive" in trait_names
    end

    test "renders to valid system prompt" do
      prompt = CliAgent.character() |> Character.to_system_prompt()
      assert prompt =~ "# Character: CLI Agent"
      assert prompt =~ "## Identity"
    end
  end

  describe "trust_tier/0" do
    test "returns :established" do
      assert CliAgent.trust_tier() == :established
    end
  end

  describe "required_capabilities/0" do
    test "includes orchestrator execute capability" do
      caps = CliAgent.required_capabilities()
      resources = Enum.map(caps, & &1.resource)
      assert "arbor://orchestrator/execute" in resources
    end
  end

  describe "description/0" do
    test "returns a non-empty string" do
      desc = CliAgent.description()
      assert is_binary(desc)
      assert String.length(desc) > 20
      assert desc =~ "CLI"
    end
  end

  describe "metadata/0" do
    test "includes session integration flag" do
      meta = CliAgent.metadata()
      assert meta[:session_integration] == true
    end
  end
end
