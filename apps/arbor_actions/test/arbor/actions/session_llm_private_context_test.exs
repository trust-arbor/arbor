defmodule Arbor.Actions.SessionLLMPrivateContextTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.SessionLlm.BuildPrompt

  @moduletag :fast

  test "turn prompt carries the same admitted volatile context in messages and flat prompt" do
    system = "Stable identity bytes.\nPreserve this prefix."
    goals = "## Private goals\n- finish the lunar field notebook"

    assert {:ok, result} =
             BuildPrompt.run(
               %{
                 mode: "turn",
                 messages: [
                   %{"role" => "system", "content" => system},
                   %{"role" => "user", "content" => "What should I work on?"}
                 ],
                 private_goal_context: goals,
                 recalled_memories: [%{"content" => "the notebook is on the blue shelf"}]
               },
               %{}
             )

    assert hd(result.messages) == %{"role" => "system", "content" => system}
    assert result.user_prompt == List.last(result.messages)["content"]
    assert result.user_prompt =~ goals
    assert result.user_prompt =~ "the notebook is on the blue shelf"
    assert result.user_prompt =~ "What should I work on?"
  end

  test "canonical string input is admitted and unproven agent-global sections are omitted" do
    assert {:ok, result} =
             BuildPrompt.run(
               %{
                 "mode" => "turn",
                 "messages" => [%{"role" => "user", "content" => "Hello"}],
                 "private_goal_context" => "## Private goals\n- scoped goal",
                 "goals" => [%{"description" => "foreign global goal"}],
                 "working_memory" => %{"note" => "foreign global working memory"},
                 "self_knowledge" => "foreign global identity",
                 "active_intents" => [%{"description" => "foreign global intent"}]
               },
               %{}
             )

    assert result.user_prompt =~ "scoped goal"
    refute inspect(result) =~ "foreign global"
  end

  test "empty sections preserve messages and an empty history has an empty flat prompt" do
    messages = [%{"role" => "user", "content" => "plain input"}]

    assert {:ok, %{messages: ^messages, user_prompt: "plain input"}} =
             BuildPrompt.run(%{mode: "turn", messages: messages}, %{})

    assert {:ok, %{messages: [], user_prompt: ""}} = BuildPrompt.run(%{mode: "turn"}, %{})
  end
end
