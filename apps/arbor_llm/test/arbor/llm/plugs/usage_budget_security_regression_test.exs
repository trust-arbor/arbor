defmodule Arbor.LLM.Plugs.UsageBudgetSecurityRegressionTest do
  @moduledoc """
  Security regression: LLM spend is refused until an operator sets a cap.

  The default budget is `$0`. Unconfigured and unidentified callers must not
  reach a provider. A configured cap admits spend only up to that limit.
  """

  use ExUnit.Case, async: false

  alias Arbor.LLM.Call
  alias Arbor.LLM.Plugs.Usage

  @event [:arbor, :llm, :usage]
  @moduletag :fast
  @moduletag :security_regression

  setup do
    previous = Application.get_env(:arbor_llm, Usage, :unset)

    Application.put_env(:arbor_llm, Usage,
      default_max_cost_usd: 1.0,
      agent_max_cost_usd: %{},
      key_max_cost_usd: %{}
    )

    handler_id = "usage-budget-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        @event,
        fn event, measurements, metadata, _ ->
          send(test_pid, {:usage_event, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)

      case previous do
        :unset -> Application.delete_env(:arbor_llm, Usage)
        value -> Application.put_env(:arbor_llm, Usage, value)
      end
    end)

    Usage.reset_cost_ledger()
    :ok
  end

  test "security regression: an unconfigured caller is refused before the provider" do
    clear_usage_budget_config()

    blocked =
      Call.new(:complete, {model(), [], []})
      |> Call.put_metadata(%{principal_id: unique_agent("unconfigured")})
      |> Usage.call()

    assert blocked.halted
    assert {:error, {:budget_not_configured, message}} = blocked.result
    assert message =~ "config :arbor_llm, Arbor.LLM.Plugs.Usage, :default_max_cost_usd"
    assert message =~ "ARBOR_LLM_USAGE_BUDGET_USD"
    assert is_nil(blocked.metadata[:usage_emitted])
  end

  test "security regression: an unidentified caller is refused before the provider" do
    clear_usage_budget_config()

    blocked = Usage.call(Call.new(:complete, {model(), [], []}))

    assert blocked.halted
    assert {:error, {:budget_not_configured, message}} = blocked.result
    assert message =~ "config :arbor_llm, Arbor.LLM.Plugs.Usage, :unidentified_max_cost_usd"
    assert message =~ "ARBOR_LLM_UNIDENTIFIED_USAGE_BUDGET_USD"
    assert is_nil(blocked.metadata[:usage_emitted])
  end

  test "security regression: a configured cap allows spend up to the limit" do
    agent_id = unique_agent("limit")
    first = Usage.call(attributed_call(agent_id, 0.6))
    second = Usage.call(attributed_call(agent_id, 0.4))
    blocked = Usage.call(attributed_call(agent_id, 0.1))

    refute first.halted
    assert first.metadata.usage_emitted
    refute match?({:error, :budget_exceeded}, first.result)
    refute match?({:error, {:budget_not_configured, _}}, first.result)

    refute second.halted
    assert second.metadata.usage_emitted

    assert blocked.halted
    assert blocked.result == {:error, :budget_exceeded}
  end

  test "security regression: an agent past its configured budget is blocked with a budget error" do
    agent_id = unique_agent("over")
    first = Usage.call(attributed_call(agent_id, 0.6))
    second = Usage.call(attributed_call(agent_id, 0.6))
    blocked = Usage.call(attributed_call(agent_id, 0.1))

    refute first.halted
    assert first.metadata.usage_emitted
    refute match?({:error, :budget_exceeded}, first.result)

    refute second.halted
    assert second.metadata.usage_emitted
    refute match?({:error, :budget_exceeded}, second.result)

    assert blocked.halted
    assert blocked.result == {:error, :budget_exceeded}
    refute Map.get(blocked.metadata, :usage_emitted, false)
    refute_receive {:usage_event, @event, %{marginal_cost_usd: 0.1}, _}, 50
  end

  test "security regression: an agent under its configured budget is admitted" do
    agent_id = unique_agent("under")
    call = Usage.call(attributed_call(agent_id, 0.4))

    refute call.halted
    refute match?({:error, :budget_exceeded}, call.result)
    assert call.metadata.usage_emitted
    assert_receive {:usage_event, @event, %{marginal_cost_usd: 0.4}, _}
  end

  test "security regression: a pre-dispatch call is refused before a provider result exists" do
    agent_id = unique_agent("pre")
    _spent = Usage.call(attributed_call(agent_id, 1.0))

    blocked =
      Call.new(:complete, {model(), [], []})
      |> Call.put_metadata(%{principal_id: agent_id})
      |> Usage.call()

    assert blocked.halted
    assert blocked.result == {:error, :budget_exceeded}
    assert is_nil(blocked.metadata[:usage_emitted])
  end

  test "security regression: a key past its configured budget is blocked independently" do
    api_key = "sk-test-budget-#{System.unique_integer([:positive])}"
    first = Usage.call(keyed_call(api_key, 0.6))
    _second = Usage.call(keyed_call(api_key, 0.6))
    blocked = Usage.call(keyed_call(api_key, 0.1))

    refute first.halted
    assert first.metadata.usage_emitted
    assert blocked.halted
    assert blocked.result == {:error, :budget_exceeded}
  end

  test "security regression: unidentified callers stay gated even when a result is already present" do
    clear_usage_budget_config()
    blocked = Usage.call(anonymous_call(0.4))

    assert blocked.halted
    assert {:error, {:budget_not_configured, message}} = blocked.result
    assert message =~ ":unidentified_max_cost_usd"
    refute Map.get(blocked.metadata, :usage_emitted, false)
  end

  defp clear_usage_budget_config do
    Application.delete_env(:arbor_llm, Usage)
    System.delete_env("ARBOR_LLM_USAGE_BUDGET_USD")
    System.delete_env("ARBOR_LLM_UNIDENTIFIED_USAGE_BUDGET_USD")
  end

  defp unique_agent(label) do
    "agent_budget_#{label}_#{System.unique_integer([:positive])}"
  end

  defp attributed_call(agent_id, cost) do
    Call.new(:complete, {model(), [], []})
    |> Call.put_metadata(%{principal_id: agent_id})
    |> Map.put(:result, {:ok, response(cost)})
  end

  defp keyed_call(api_key, cost) do
    Call.new(:complete, {model(), [], [api_key: api_key]})
    |> Map.put(:result, {:ok, response(cost)})
  end

  defp anonymous_call(cost) do
    Call.new(:complete, {model(), [], []})
    |> Map.put(:result, {:ok, response(cost)})
  end

  defp model do
    LLMDB.Model.new!(%{id: "gpt-4", provider: :openai})
  end

  defp response(cost) do
    %ReqLLM.Response{
      id: "resp-budget",
      model: "gpt-4",
      context: ReqLLM.Context.new([]),
      message: nil,
      stream?: false,
      stream: nil,
      usage: %{
        input_tokens: 2,
        output_tokens: 1,
        total_tokens: 3,
        total_cost: cost
      },
      finish_reason: :stop,
      provider_meta: %{},
      error: nil
    }
  end
end
