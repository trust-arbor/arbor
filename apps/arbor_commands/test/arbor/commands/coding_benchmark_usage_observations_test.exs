defmodule Arbor.Commands.CodingBenchmark.UsageObservationsTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.CodingBenchmark.UsageObservations

  @moduletag :fast

  test "projects snake_case and camelCase aliases into closed observations" do
    assert UsageObservations.from_usage(%{
             "inputTokens" => 12,
             "output_tokens" => 3,
             "completionTokens" => 99,
             "totalTokens" => 15,
             "cacheReadInputTokens" => 2,
             "cost" => 7
           }) == %{
             "input_tokens" => 12,
             "output_tokens" => 3,
             "total_tokens" => 15,
             "cache_read_input_tokens" => 2,
             "cost_ticks" => 7
           }
  end

  test "prefers the first listed alias and labels provider cost as ticks" do
    assert UsageObservations.from_usage(%{
             "input_tokens" => 1,
             "prompt_tokens" => 999,
             "cost_ticks" => 4,
             "cost" => 8
           }) == %{
             "input_tokens" => 1,
             "cost_ticks" => 4
           }

    refute Map.has_key?(
             UsageObservations.from_usage(%{"cost" => 1.5}),
             "cost_usd"
           )
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

  test "rejects malformed, negative, non-finite, and oversized values fail-closed per field" do
    huge = 9_223_372_036_854_775_808

    assert UsageObservations.from_usage(%{
             "input_tokens" => -1,
             "output_tokens" => :nan,
             "total_tokens" => huge,
             "cache_read_input_tokens" => "12",
             "cost" => %{"total" => 1},
             "prompt_tokens" => 5
           }) == %{"input_tokens" => 5}

    assert UsageObservations.from_usage(%{
             "input_tokens" => -0.5,
             "output_tokens" => :infinity,
             "cost" => :"-inf"
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
        "usd" => 0.02
      })

    assert projected == %{"input_tokens" => 9}
    assert Map.keys(projected) == ["input_tokens"]
  end
end
