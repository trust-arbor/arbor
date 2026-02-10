defmodule Arbor.Orchestrator.Conformance49Test do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.FanInHandler

  defp fan_in_node(attrs \\ %{}) do
    %Node{id: "join", attrs: attrs}
  end

  test "4.9 fails when no parallel results are available" do
    outcome = FanInHandler.execute(fan_in_node(), Context.new(%{}), %{}, [])
    assert outcome.status == :fail
    assert outcome.failure_reason == "No parallel results to evaluate"
  end

  test "4.9 fails when all candidates fail" do
    context =
      Context.new(%{
        "parallel.results" => [
          %{"id" => "a", "status" => "fail", "score" => 0.2},
          %{"id" => "b", "status" => "fail", "score" => 0.8}
        ]
      })

    outcome = FanInHandler.execute(fan_in_node(), context, %{}, [])
    assert outcome.status == :fail
    assert outcome.failure_reason == "All parallel candidates failed"
  end

  test "4.9 heuristic ranking uses status then score then id" do
    context =
      Context.new(%{
        "parallel.results" => [
          %{"id" => "b", "status" => "success", "score" => 0.7},
          %{"id" => "a", "status" => "success", "score" => 0.7},
          %{"id" => "c", "status" => "partial_success", "score" => 0.99}
        ]
      })

    outcome = FanInHandler.execute(fan_in_node(), context, %{}, [])
    assert outcome.status == :success
    assert outcome.context_updates["parallel.fan_in.best_id"] == "a"
    assert outcome.context_updates["parallel.fan_in.best_outcome"] == "success"
  end

  test "4.9 prompt-based evaluation uses fan_in_evaluator when provided" do
    context =
      Context.new(%{
        "parallel.results" => [
          %{"id" => "a", "status" => "success", "score" => 0.1},
          %{"id" => "b", "status" => "success", "score" => 0.9}
        ]
      })

    node = fan_in_node(%{"prompt" => "Pick by external evaluator"})

    evaluator = fn prompt, results ->
      assert prompt =~ "external evaluator"
      assert length(results) == 2
      "a"
    end

    outcome = FanInHandler.execute(node, context, %{}, fan_in_evaluator: evaluator)
    assert outcome.status == :success
    assert outcome.context_updates["parallel.fan_in.best_id"] == "a"
  end

  test "4.9 prompt evaluator falls back to heuristic on invalid selection" do
    context =
      Context.new(%{
        "parallel.results" => [
          %{"id" => "a", "status" => "success", "score" => 0.2},
          %{"id" => "b", "status" => "success", "score" => 0.9}
        ]
      })

    node = fan_in_node(%{"prompt" => "fallback"})
    evaluator = fn _prompt, _results -> "missing-id" end

    outcome = FanInHandler.execute(node, context, %{}, fan_in_evaluator: evaluator)
    assert outcome.context_updates["parallel.fan_in.best_id"] == "b"
  end
end
