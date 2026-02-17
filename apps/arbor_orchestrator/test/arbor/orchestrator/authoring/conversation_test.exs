defmodule Arbor.Orchestrator.Authoring.ConversationTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Authoring.Conversation

  describe "new/2" do
    test "creates a blank conversation" do
      conv = Conversation.new(:blank)
      assert conv.mode == :blank
      assert conv.history == []
      assert is_binary(conv.system_prompt)
      assert conv.system_prompt =~ "pipeline architect"
    end

    test "creates conversation for each mode" do
      for mode <- [:blank, :idea, :file, :evolve, :template] do
        conv = Conversation.new(mode)
        assert conv.mode == mode
        assert is_binary(conv.system_prompt)
        assert conv.system_prompt != ""
      end
    end

    test "accepts custom system_prompt" do
      conv = Conversation.new(:blank, system_prompt: "Custom prompt")
      assert conv.system_prompt == "Custom prompt"
    end
  end

  describe "add_user/2" do
    test "appends user message to history" do
      conv = Conversation.new(:blank) |> Conversation.add_user("Hello")
      assert conv.history == [{:user, "Hello"}]
    end

    test "preserves message ordering" do
      conv =
        Conversation.new(:blank)
        |> Conversation.add_user("First")
        |> Conversation.add_user("Second")

      assert conv.history == [{:user, "First"}, {:user, "Second"}]
    end
  end

  describe "add_assistant/2" do
    test "appends assistant message to history" do
      conv = Conversation.new(:blank) |> Conversation.add_assistant("Hi there")
      assert conv.history == [{:assistant, "Hi there"}]
    end
  end

  describe "to_prompt/1" do
    test "includes system prompt" do
      conv = Conversation.new(:blank)
      prompt = Conversation.to_prompt(conv)
      assert prompt =~ "SYSTEM:"
      assert prompt =~ "pipeline architect"
    end

    test "includes history messages with roles" do
      conv =
        Conversation.new(:blank, system_prompt: "Be helpful")
        |> Conversation.add_user("Create a pipeline")
        |> Conversation.add_assistant("What should it do?")
        |> Conversation.add_user("Process files")

      prompt = Conversation.to_prompt(conv)
      assert prompt =~ "USER: Create a pipeline"
      assert prompt =~ "ASSISTANT: What should it do?"
      assert prompt =~ "USER: Process files"
    end

    test "empty history produces system prompt only" do
      conv = Conversation.new(:blank, system_prompt: "System")
      prompt = Conversation.to_prompt(conv)
      assert prompt == "SYSTEM:\nSystem\n\n"
    end
  end

  describe "turn_count/1" do
    test "returns 0 for new conversation" do
      assert Conversation.turn_count(Conversation.new(:blank)) == 0
    end

    test "counts all messages" do
      conv =
        Conversation.new(:blank)
        |> Conversation.add_user("a")
        |> Conversation.add_assistant("b")
        |> Conversation.add_user("c")

      assert Conversation.turn_count(conv) == 3
    end
  end
end
