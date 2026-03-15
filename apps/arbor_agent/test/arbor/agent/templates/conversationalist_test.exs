defmodule Arbor.Agent.Templates.ConversationalistTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Agent.Character
  alias Arbor.Agent.Templates.Conversationalist

  describe "Template behaviour implementation" do
    test "implements all required callbacks" do
      Code.ensure_loaded!(Conversationalist)
      assert function_exported?(Conversationalist, :character, 0)
      assert function_exported?(Conversationalist, :trust_tier, 0)
      assert function_exported?(Conversationalist, :initial_goals, 0)
      assert function_exported?(Conversationalist, :required_capabilities, 0)
    end

    test "implements optional callbacks" do
      assert function_exported?(Conversationalist, :description, 0)
      assert function_exported?(Conversationalist, :metadata, 0)
      assert function_exported?(Conversationalist, :nature, 0)
      assert function_exported?(Conversationalist, :values, 0)
      assert function_exported?(Conversationalist, :relationship_style, 0)
    end
  end

  describe "character/0" do
    test "returns a valid Character struct named River" do
      char = Conversationalist.character()
      assert %Character{} = char
      assert char.name == "River"
      assert char.role == "Conversationalist"
    end

    test "has curious and empathetic traits" do
      char = Conversationalist.character()
      assert length(char.traits) == 4

      trait_names = Enum.map(char.traits, & &1.name)
      assert "curious" in trait_names
      assert "empathetic" in trait_names
      assert "philosophical" in trait_names
    end

    test "values honesty and genuine connection" do
      char = Conversationalist.character()
      assert "honesty" in char.values
      assert "genuine connection" in char.values
    end

    test "has warm tone" do
      char = Conversationalist.character()
      assert char.tone == "warm"
    end

    test "renders to valid system prompt" do
      prompt = Conversationalist.character() |> Character.to_system_prompt()
      assert prompt =~ "# Character: River"
      assert prompt =~ "## Identity"
    end
  end

  describe "trust_tier/0" do
    test "returns :established" do
      assert Conversationalist.trust_tier() == :established
    end
  end

  describe "required_capabilities/0" do
    test "includes orchestrator execute capability" do
      caps = Conversationalist.required_capabilities()
      resources = Enum.map(caps, & &1.resource)
      assert "arbor://orchestrator/execute" in resources
    end
  end

  describe "metadata/0" do
    test "includes context management and category" do
      meta = Conversationalist.metadata()
      assert meta[:category] == :conversational
      assert meta[:context_management] == :heuristic
    end
  end

  describe "description/0" do
    test "returns a non-empty string mentioning conversation" do
      desc = Conversationalist.description()
      assert is_binary(desc)
      assert String.length(desc) > 20
      assert desc =~ "conversation" or desc =~ "Conversation"
    end
  end
end
