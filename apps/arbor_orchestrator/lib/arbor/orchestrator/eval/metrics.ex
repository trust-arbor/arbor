defmodule Arbor.Orchestrator.Eval.Metrics do
  @moduledoc """
  Built-in metric computations for eval results.

  Metrics:
    - `accuracy` — fraction of samples that passed all graders
    - `mean_score` — average score across all samples
    - `pass_at_k` — unbiased estimator of passing at least once in k attempts
  """

  @doc "Computes a named metric over a list of result maps."
  @spec compute(String.t(), [map()], keyword()) :: float()
  def compute("accuracy", results, _opts) do
    if results == [] do
      0.0
    else
      passed = Enum.count(results, &result_passed?/1)
      passed / length(results)
    end
  end

  def compute("mean_score", results, _opts) do
    if results == [] do
      0.0
    else
      total = Enum.reduce(results, 0.0, fn r, acc -> acc + result_score(r) end)
      total / length(results)
    end
  end

  def compute("pass_at_k", results, opts) do
    k = Keyword.get(opts, :k, 1)

    # Group by sample id
    grouped =
      Enum.group_by(results, fn r -> r["id"] || r[:id] || "unknown" end)

    if map_size(grouped) == 0 do
      0.0
    else
      pass_rates =
        Enum.map(grouped, fn {_id, group} ->
          n = length(group)
          c = Enum.count(group, &result_passed?/1)
          pass_at_k_single(n, c, k)
        end)

      Enum.sum(pass_rates) / length(pass_rates)
    end
  end

  def compute(_name, _results, _opts), do: 0.0

  @doc "Returns all known metric names."
  @spec known_metrics() :: [String.t()]
  def known_metrics, do: ["accuracy", "mean_score", "pass_at_k"]

  # pass@k = 1 - C(n-c, k) / C(n, k)
  defp pass_at_k_single(n, c, k) when n >= k and c >= 0 do
    if c == n do
      1.0
    else
      1.0 - combinations(n - c, k) / combinations(n, k)
    end
  end

  defp pass_at_k_single(_n, _c, _k), do: 0.0

  defp combinations(n, k) when k > n, do: 0.0
  defp combinations(_n, 0), do: 1.0
  defp combinations(n, k) when k > n - k, do: combinations(n, n - k)

  defp combinations(n, k) do
    Enum.reduce(0..(k - 1), 1.0, fn i, acc ->
      acc * (n - i) / (i + 1)
    end)
  end

  defp result_passed?(result) do
    # A result passes if all grader scores passed
    scores = result["scores"] || result[:scores] || []

    if scores == [] do
      # Single-grader format
      result["passed"] || result[:passed] || false
    else
      Enum.all?(scores, fn s -> s["passed"] || s[:passed] || false end)
    end
  end

  defp result_score(result) do
    scores = result["scores"] || result[:scores] || []

    if scores == [] do
      result["score"] || result[:score] || 0.0
    else
      avg =
        scores
        |> Enum.map(fn s -> s["score"] || s[:score] || 0.0 end)
        |> then(fn
          [] -> 0.0
          list -> Enum.sum(list) / length(list)
        end)

      avg
    end
  end
end
