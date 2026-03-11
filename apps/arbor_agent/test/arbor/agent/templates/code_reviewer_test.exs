defmodule Arbor.Agent.Templates.CodeReviewerTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Agent.Character
  alias Arbor.Agent.Templates.CodeReviewer

  describe "Template behaviour implementation" do
    test "implements all required callbacks" do
      Code.ensure_loaded!(CodeReviewer)
      assert function_exported?(CodeReviewer, :character, 0)
      assert function_exported?(CodeReviewer, :trust_tier, 0)
      assert function_exported?(CodeReviewer, :initial_goals, 0)
      assert function_exported?(CodeReviewer, :required_capabilities, 0)
    end

    test "implements optional callbacks" do
      assert function_exported?(CodeReviewer, :description, 0)
      assert function_exported?(CodeReviewer, :nature, 0)
      assert function_exported?(CodeReviewer, :values, 0)
      assert function_exported?(CodeReviewer, :domain_context, 0)
    end
  end

  describe "character/0" do
    test "returns a valid Character struct" do
      char = CodeReviewer.character()
      assert %Character{} = char
      assert char.name == "Code Reviewer"
      assert char.role == "Security-conscious code reviewer"
    end

    test "has detail-oriented and constructive traits" do
      char = CodeReviewer.character()
      assert length(char.traits) == 2

      trait_names = Enum.map(char.traits, & &1.name)
      assert "detail-oriented" in trait_names
      assert "constructive" in trait_names

      detail = Enum.find(char.traits, &(&1.name == "detail-oriented"))
      assert detail.intensity >= 0.9
    end

    test "values security and correctness" do
      char = CodeReviewer.character()
      assert "correctness" in char.values
      assert "security" in char.values
      assert "maintainability" in char.values
    end

    test "instructions mention OWASP" do
      char = CodeReviewer.character()
      instructions_text = Enum.join(char.instructions, " ")
      assert instructions_text =~ "OWASP"
    end

    test "renders to valid system prompt" do
      prompt = CodeReviewer.character() |> Character.to_system_prompt()
      assert prompt =~ "# Character: Code Reviewer"
      assert prompt =~ "## Identity"
      assert prompt =~ "## Personality"
    end
  end

  describe "trust_tier/0" do
    test "returns :probationary" do
      assert CodeReviewer.trust_tier() == :probationary
    end
  end

  describe "required_capabilities/0" do
    test "includes read and safe shell access" do
      caps = CodeReviewer.required_capabilities()
      resources = Enum.map(caps, & &1.resource)
      assert Enum.any?(resources, &(&1 =~ "fs/read"))
      assert Enum.any?(resources, &(&1 =~ "shell/safe"))
    end
  end

  describe "description/0" do
    test "returns a non-empty string mentioning security" do
      desc = CodeReviewer.description()
      assert is_binary(desc)
      assert String.length(desc) > 20
      assert desc =~ "security" or desc =~ "Security"
    end
  end
end
