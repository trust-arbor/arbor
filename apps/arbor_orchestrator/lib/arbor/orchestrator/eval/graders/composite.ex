defmodule Arbor.Orchestrator.Eval.Graders.Composite do
  @moduledoc """
  Grader that combines multiple graders with a strategy.

  Options:
    - `:graders` — list of `{grader_module, weight}` tuples or `{grader_module, weight, grader_opts}`
    - `:strategy` — `:weighted_avg` (default), `:all_pass`, or `:any_pass`
  """

  @behaviour Arbor.Orchestrator.Eval.Grader

  @impl true
  def grade(actual, expected, opts \\ []) do
    graders = Keyword.get(opts, :graders, [])
    strategy = Keyword.get(opts, :strategy, :weighted_avg)

    results =
      Enum.map(graders, fn
        {module, weight, grader_opts} ->
          {module.grade(actual, expected, grader_opts), weight}

        {module, weight} ->
          {module.grade(actual, expected, []), weight}
      end)

    case strategy do
      :weighted_avg -> weighted_average(results)
      :all_pass -> all_pass(results)
      :any_pass -> any_pass(results)
    end
  end

  defp weighted_average(results) do
    total_weight = results |> Enum.map(fn {_r, w} -> w end) |> Enum.sum()

    if total_weight == 0 do
      %{score: 0.0, passed: false, detail: "no graders configured"}
    else
      score =
        results
        |> Enum.map(fn {r, w} -> r.score * w end)
        |> Enum.sum()
        |> Kernel./(total_weight)

      passed = score >= 0.5

      details =
        results
        |> Enum.map(fn {r, w} -> "#{Float.round(r.score, 3)}*#{w}" end)
        |> Enum.join(" + ")

      %{
        score: score,
        passed: passed,
        detail: "weighted_avg(#{details}) = #{Float.round(score, 3)}"
      }
    end
  end

  defp all_pass(results) do
    all_passed = Enum.all?(results, fn {r, _w} -> r.passed end)
    avg = avg_score(results)

    %{
      score: avg,
      passed: all_passed,
      detail:
        "all_pass: #{Enum.count(results, fn {r, _} -> r.passed end)}/#{length(results)} passed"
    }
  end

  defp any_pass(results) do
    any_passed = Enum.any?(results, fn {r, _w} -> r.passed end)
    avg = avg_score(results)

    %{
      score: avg,
      passed: any_passed,
      detail:
        "any_pass: #{Enum.count(results, fn {r, _} -> r.passed end)}/#{length(results)} passed"
    }
  end

  defp avg_score(results) do
    scores = Enum.map(results, fn {r, _w} -> r.score end)

    if scores == [] do
      0.0
    else
      Enum.sum(scores) / length(scores)
    end
  end
end
