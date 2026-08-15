defmodule Arbor.Eval.MetricsTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Eval.Metrics

  test "preserves accuracy and mean-score semantics for nested score maps" do
    results = [
      %{"scores" => [%{"passed" => true, "score" => 1.0}]},
      %{"scores" => [%{passed: false, score: 0.25}, %{passed: true, score: 0.75}]}
    ]

    assert Metrics.compute("accuracy", results, []) == 0.5
    assert Metrics.compute("mean_score", results, []) == 0.75
  end

  test "preserves single-grader and empty-result semantics" do
    results = [
      %{"passed" => true, "score" => 1.0},
      %{passed: false, score: 0.0}
    ]

    assert Metrics.compute("accuracy", results, []) == 0.5
    assert Metrics.compute("mean_score", results, []) == 0.5
    assert Metrics.compute("accuracy", [], []) == 0.0
    assert Metrics.compute("mean_score", [], []) == 0.0
    assert Metrics.compute("unknown", results, []) == 0.0
  end

  test "computes the existing unbiased pass-at-k estimator by sample id" do
    results = [
      %{"id" => "sample", "passed" => true},
      %{"id" => "sample", "passed" => false},
      %{"id" => "sample", "passed" => false}
    ]

    assert_in_delta Metrics.compute("pass_at_k", results, k: 2), 2.0 / 3.0, 1.0e-12
    assert Metrics.compute("pass_at_k", [], k: 2) == 0.0
    assert Metrics.known_metrics() == ["accuracy", "mean_score", "pass_at_k"]
  end
end
