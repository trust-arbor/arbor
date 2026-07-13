defmodule Arbor.Consensus.LLMBridgeNestedCostTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arbor.Consensus.LLMBridge

  @moduletag :fast

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)
  end

  test "regression: nested cost map does not abort a successful completion" do
    nested_cost = %{
      total: 0.001_234_5,
      input_cost: 0.001,
      output_cost: 0.000_234_5,
      line_items: [%{name: "input", cost: 0.001}]
    }

    usage = %{input_tokens: 10, output_tokens: 5, total_tokens: 15, cost: nested_cost}

    log =
      capture_log([level: :info], fn ->
        assert {:ok, result} = complete_with(usage)
        assert result.text == "council answer"
        assert is_integer(result.duration_ms)
        assert result.usage == usage
      end)

    assert log =~ "tokens=15 cost=$0.0012"
  end

  test "unknown nested cost omits the suffix without changing the successful result" do
    usage = %{
      total_tokens: 3,
      cost: %{line_items: [%{name: "input", amount: "unknown"}], currency: "USD"}
    }

    log =
      capture_log([level: :info], fn ->
        assert {:ok, result} = complete_with(usage)
        assert result.usage == usage
      end)

    assert log =~ "tokens=3"
    refute log =~ "cost=$"
  end

  test "string-keyed nested and top-level totals are recognized" do
    nested = %{"total_tokens" => 7, "cost" => %{"total" => 0.5}}
    top_level = %{total_tokens: 1, total_cost: 0.25, cost: %{line_items: []}}

    assert capture_completion_log(nested) =~ "tokens=7 cost=$0.5000"
    assert capture_completion_log(top_level) =~ "tokens=1 cost=$0.2500"
  end

  test "large integer costs are formatted without float conversion" do
    cost = 10 ** 400
    usage = %{total_tokens: 1, cost: cost}

    log = capture_completion_log(usage)

    assert log =~ "cost=$#{cost}"
  end

  test "injected completion errors preserve the public error contract" do
    assert {:error, :provider_down} =
             LLMBridge.complete("system", "user",
               complete_fun: fn _, _, _ -> {:error, :provider_down} end
             )
  end

  defp complete_with(usage) do
    LLMBridge.complete("system", "user",
      provider: "test",
      model: "test-model",
      complete_fun: fn _system, _user, opts ->
        refute Keyword.has_key?(opts, :complete_fun)
        {:ok, "council answer", usage}
      end
    )
  end

  defp capture_completion_log(usage) do
    capture_log([level: :info], fn -> assert {:ok, _result} = complete_with(usage) end)
  end
end
