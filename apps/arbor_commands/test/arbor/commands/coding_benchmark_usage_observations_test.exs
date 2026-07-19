defmodule Arbor.Commands.CodingBenchmark.UsageObservationsTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.CodingBenchmark.UsageObservations

  @moduletag :fast

  # Exact Grok ACP turn_completed usage shape observed in local provider evidence.
  @grok_turn_completed_usage %{
    "inputTokens" => 1_200,
    "outputTokens" => 340,
    "totalTokens" => 1_540,
    "cachedReadTokens" => 88,
    "reasoningTokens" => 55,
    "modelCalls" => 3,
    "apiDurationMs" => 4_200,
    "costUsdTicks" => 17,
    "numTurns" => 2,
    "modelUsage" => %{
      "grok-4" => %{"inputTokens" => 1_200, "outputTokens" => 340}
    }
  }

  test "projects the exact Grok turn_completed usage shape with neutral names" do
    assert UsageObservations.from_usage(@grok_turn_completed_usage) == %{
             "input_tokens" => 1_200,
             "output_tokens" => 340,
             "total_tokens" => 1_540,
             "cached_read_tokens" => 88,
             "reasoning_tokens" => 55,
             "model_calls" => 3,
             "api_duration_ms" => 4_200,
             "cost_ticks" => 17,
             "num_turns" => 2
           }
  end

  test "excludes nested modelUsage and never labels cost as USD" do
    projected = UsageObservations.from_usage(@grok_turn_completed_usage)

    refute Map.has_key?(projected, "modelUsage")
    refute Map.has_key?(projected, "model_usage")
    refute Map.has_key?(projected, "cost_usd")
    refute Map.has_key?(projected, "costUsd")
    assert projected["cost_ticks"] == 17
  end

  test "does not accept generic provider cost as cost_ticks" do
    assert UsageObservations.from_usage(%{"cost" => 9, "costUsdTicks" => 2}) == %{
             "cost_ticks" => 2
           }

    assert UsageObservations.from_usage(%{"cost" => 9}) == %{}
  end

  test "projects snake_case and camelCase aliases into closed observations" do
    assert UsageObservations.from_usage(%{
             "inputTokens" => 12,
             "output_tokens" => 3,
             "completionTokens" => 99,
             "totalTokens" => 15,
             "cachedReadTokens" => 2,
             "costUsdTicks" => 7
           }) == %{
             "input_tokens" => 12,
             "output_tokens" => 3,
             "total_tokens" => 15,
             "cached_read_tokens" => 2,
             "cost_ticks" => 7
           }
  end

  test "prefers the first present alias and does not fall through on malformed preferred values" do
    assert UsageObservations.from_usage(%{
             "input_tokens" => 1,
             "prompt_tokens" => 999,
             "cost_ticks" => 4,
             "costUsdTicks" => 8
           }) == %{
             "input_tokens" => 1,
             "cost_ticks" => 4
           }

    # First present alias is input_tokens; it is malformed, so the field is
    # omitted even though prompt_tokens is a valid secondary alias.
    assert UsageObservations.from_usage(%{
             "input_tokens" => -1,
             "prompt_tokens" => 5,
             "output_tokens" => 2
           }) == %{"output_tokens" => 2}

    assert UsageObservations.from_usage(%{
             "inputTokens" => "bad",
             "prompt_tokens" => 11
           }) == %{}
  end

  test "extracts usage and context tokens from metrics and coding results" do
    metrics = %{
      "usage" => %{"input_tokens" => 100, "outputTokens" => 20},
      "context_tokens" => 80
    }

    assert UsageObservations.from_metrics(metrics) == %{
             "input_tokens" => 100,
             "output_tokens" => 20,
             "context_tokens" => 80
           }

    result = %{
      "result_type" => "coding_change",
      "payload" => %{
        "metrics" => metrics,
        "report" => %{"status" => "change_committed"}
      }
    }

    assert UsageObservations.from_result(result) == %{
             "input_tokens" => 100,
             "output_tokens" => 20,
             "context_tokens" => 80
           }
  end

  test "pipeline-style metrics usage is accepted" do
    assert UsageObservations.from_result(%{
             "metrics" => %{
               "execution_path" => "pipeline",
               "usage" => %{"input_tokens" => 5_000, "output_tokens" => 800}
             }
           }) == %{"input_tokens" => 5_000, "output_tokens" => 800}
  end

  test "projects Grok usage nested under result metrics" do
    assert UsageObservations.from_result(%{
             "metrics" => %{
               "execution_path" => "legacy",
               "usage" => @grok_turn_completed_usage
             }
           }) == %{
             "input_tokens" => 1_200,
             "output_tokens" => 340,
             "total_tokens" => 1_540,
             "cached_read_tokens" => 88,
             "reasoning_tokens" => 55,
             "model_calls" => 3,
             "api_duration_ms" => 4_200,
             "cost_ticks" => 17,
             "num_turns" => 2
           }
  end

  test "rejects malformed, negative, non-finite, and oversized values fail-closed per field" do
    huge = 9_223_372_036_854_775_808

    assert UsageObservations.from_usage(%{
             "input_tokens" => -1,
             "output_tokens" => :nan,
             "total_tokens" => huge,
             "cachedReadTokens" => "12",
             "costUsdTicks" => %{"total" => 1},
             "modelCalls" => 3
           }) == %{"model_calls" => 3}

    assert UsageObservations.from_usage(%{
             "input_tokens" => -0.5,
             "output_tokens" => :infinity,
             "costUsdTicks" => :"-inf"
           }) == %{}
  end

  test "nil and non-map inputs project to empty observations" do
    assert UsageObservations.from_usage(nil) == %{}
    assert UsageObservations.from_metrics(nil) == %{}
    assert UsageObservations.from_result(nil) == %{}
    assert UsageObservations.from_result([]) == %{}
    assert UsageObservations.from_metrics(%{"usage" => nil}) == %{}
  end

  test "ignores unknown fields and keeps only the closed observation set" do
    projected =
      UsageObservations.from_usage(%{
        "input_tokens" => 9,
        "model" => "grok",
        "provider" => "xai",
        "usd" => 0.02,
        "modelUsage" => %{"nested" => 1}
      })

    assert projected == %{"input_tokens" => 9}
    assert Map.keys(projected) == ["input_tokens"]
  end
end
