defmodule Arbor.Actions.SessionLLMPromptProvenanceTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.SessionLlm.BuildPrompt

  @moduletag :fast

  @message_boundary "\n\n---\n\n## Current user message\n"

  test "regression: retrieved context is distinct from a typed follow-up after voice" do
    system = %{"role" => "system", "content" => "Stable identity bytes.\nKeep this prefix."}

    history = [
      system,
      %{"role" => "user", "content" => "Remember the test phrase: silver birch."},
      %{"role" => "assistant", "content" => "The test phrase is silver birch."},
      %{
        "role" => "user",
        "content" => [%{"type" => "text", "text" => "Can you repeat the test phrase?"}]
      },
      %{
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => "Would you like me to repeat silver birch?"}]
      }
    ]

    input = "yes please"
    goals = "## Private goals\n- Finish the voice continuity check"

    assert {:ok, result} =
             BuildPrompt.run(
               %{
                 mode: "turn",
                 messages: history ++ [%{"role" => "user", "content" => input}],
                 private_goal_context: goals,
                 recalled_memories: [%{"content" => "An earlier check used cedar."}]
               },
               %{}
             )

    assert String.starts_with?(result.user_prompt, "## Context supplied by Arbor\n")
    assert [context, ^input] = String.split(result.user_prompt, @message_boundary, parts: 2)
    assert context =~ "not as the current user's message"
    assert context =~ "do not replace the preceding conversation"
    assert context =~ "## Retrieved memories\n- An earlier check used cedar."
    assert context =~ goals
    refute context =~ "memories from past sessions"
    assert Enum.drop(result.messages, -1) == history
    assert Enum.filter(result.messages, &(&1["role"] == "system")) == [system]
    assert List.last(result.messages) == %{"role" => "user", "content" => result.user_prompt}
  end

  test "no supplemental context preserves all message and current input bytes" do
    input = "  yes please\n\t"

    messages = [
      %{"role" => "system", "content" => " Stable prefix.\n"},
      %{"role" => "user", "content" => "Earlier user wording."},
      %{"role" => "assistant", "content" => "Would you like to continue?"},
      %{"role" => "user", "content" => input}
    ]

    assert {:ok, %{messages: ^messages, user_prompt: ^input}} =
             BuildPrompt.run(%{mode: "turn", messages: messages, recalled_memories: []}, %{})
  end

  test "framing preserves whitespace and Unicode in the current user message" do
    input = "  yes please — café\n\tkeep  these spaces\n"

    assert {:ok, result} =
             BuildPrompt.run(
               %{
                 mode: "turn",
                 messages: [%{"role" => "user", "content" => input}],
                 recalled_memories: [%{"content" => "A retrieved detail."}]
               },
               %{}
             )

    assert [_context, ^input] = String.split(result.user_prompt, @message_boundary, parts: 2)
    assert [%{"role" => "user", "content" => content}] = result.messages
    assert content == result.user_prompt
  end

  test "goals without recall are framed only on the latest user message" do
    history = [
      %{"role" => "user", "content" => "First user message.\n"},
      %{"role" => "assistant", "content" => "First reply."},
      %{"role" => "user", "content" => "Second user message."},
      %{"role" => "assistant", "content" => "Second reply."}
    ]

    input = "Continue."
    goals = "## Private goals\n- Complete the current task"

    assert {:ok, result} =
             BuildPrompt.run(
               %{
                 mode: "turn",
                 messages: history ++ [%{"role" => "user", "content" => input}],
                 private_goal_context: goals
               },
               %{}
             )

    assert Enum.drop(result.messages, -1) == history
    assert [context, ^input] = String.split(result.user_prompt, @message_boundary, parts: 2)
    assert String.starts_with?(context, "## Context supplied by Arbor\n")
    assert context =~ goals
    refute context =~ "## Retrieved memories"
    refute Enum.any?(result.messages, &(&1["role"] == "system"))
    assert List.last(result.messages)["content"] == result.user_prompt
  end

  test "context without a current user message remains explicitly attributed" do
    system = %{"role" => "system", "content" => "Stable system prefix."}

    assert {:ok, result} =
             BuildPrompt.run(
               %{
                 mode: "turn",
                 messages: [system],
                 recalled_memories: [%{"content" => "A retrieved detail."}]
               },
               %{}
             )

    assert [^system, %{"role" => "user", "content" => context}] = result.messages
    assert String.starts_with?(context, "## Context supplied by Arbor\n")
    assert context =~ "## Retrieved memories\n- A retrieved detail."
    refute context =~ @message_boundary
    assert result.user_prompt == context
  end
end
