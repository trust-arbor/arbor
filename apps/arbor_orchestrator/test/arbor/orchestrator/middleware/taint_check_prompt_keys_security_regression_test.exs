defmodule Arbor.Orchestrator.Middleware.TaintCheckPromptKeysSecurityRegressionTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Middleware.{TaintCheck, Token}

  # 2026-10-11 cross-library review F-006: the stock turn.dot / heartbeat.dot
  # compute nodes read their prompt via `prompt_context_key`, which TaintCheck
  # never scanned. `__data_sensitivity__` was therefore never derived from the
  # bytes actually sent to the model, so the sensitivity router and the
  # model-policy admission added in 6f17a3dd9 were dormant on every agent turn.
  @anthropic_key "sk-ant-api03-" <> String.duplicate("A1b2C3d4", 12)

  defp token(attrs, context_map) do
    %Token{
      node: %{
        id: "compute_1",
        attrs: Map.merge(%{"type" => "compute", "simulate" => "false"}, attrs),
        taint_profile: nil
      },
      context: Context.new(context_map),
      graph: %{attrs: %{}},
      assigns: %{}
    }
  end

  test "security regression (F-006): a secret in the prompt_context_key value classifies the node :restricted" do
    result =
      TaintCheck.before_node(
        token(
          %{"prompt_context_key" => "session.user_prompt"},
          %{"session.user_prompt" => "please use my key #{@anthropic_key} to call the api"}
        )
      )

    refute result.halted
    assert Context.get(result.context, "__data_sensitivity__") == :restricted
  end

  test "security regression (F-006): the system_prompt_context_key value is scanned too" do
    result =
      TaintCheck.before_node(
        token(
          %{"system_prompt_context_key" => "session.system_prompt"},
          %{"session.system_prompt" => "system: token #{@anthropic_key}"}
        )
      )

    assert Context.get(result.context, "__data_sensitivity__") == :restricted
  end

  test "a secret under an unrelated context key is not attributed to the node" do
    result =
      TaintCheck.before_node(
        token(
          %{"prompt_context_key" => "session.user_prompt"},
          %{"session.user_prompt" => "hello", "session.unrelated" => @anthropic_key}
        )
      )

    assert is_nil(Context.get(result.context, "__data_sensitivity__"))
  end
end
