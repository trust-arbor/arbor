defmodule Arbor.Eval.Report do
  @moduledoc """
  Pure terminal, JSON, and Markdown formatting for evaluation reports.

  This module returns report content only. File writes and other effects belong
  at the caller's imperative boundary.
  """

  @doc "Formats evaluation results and metrics in the requested format."
  @spec format([map()], map(), String.t()) :: String.t()
  def format(results, metrics, "json") do
    Jason.encode!(%{"results" => results, "metrics" => metrics}, pretty: true)
  end

  def format(results, metrics, "markdown") do
    total = length(results)
    passed = Enum.count(results, & &1["passed"])
    failed = total - passed

    metrics_section =
      Enum.map_join(metrics, "\n", fn {key, value} ->
        "| #{key} | #{format_value(value)} |"
      end)

    failures =
      results
      |> Enum.reject(& &1["passed"])
      |> Enum.take(5)
      |> Enum.map_join("\n", fn result ->
        "- **#{result["id"]}**: expected=`#{truncate(result["expected"], 60)}` actual=`#{truncate(to_string(result["actual"]), 60)}`"
      end)

    """
    # Evaluation Report

    **Samples:** #{total} total, #{passed} passed, #{failed} failed

    ## Metrics

    | Metric | Value |
    |--------|-------|
    #{metrics_section}

    ## Top Failures

    #{if failures == "", do: "_None_", else: failures}
    """
  end

  def format(results, metrics, _terminal) do
    total = length(results)
    passed = Enum.count(results, & &1["passed"])

    metrics_lines =
      Enum.map_join(metrics, "\n", fn {key, value} ->
        "  #{key}: #{format_value(value)}"
      end)

    failures =
      results
      |> Enum.reject(& &1["passed"])
      |> Enum.take(3)
      |> Enum.map_join("\n", fn result ->
        "  - #{result["id"]}: expected=#{truncate(result["expected"], 40)} actual=#{truncate(to_string(result["actual"]), 40)}"
      end)

    """
    === Evaluation Report ===
    Samples: #{total} | Passed: #{passed} | Failed: #{total - passed}

    Metrics:
    #{metrics_lines}
    #{if failures != "", do: "\nTop Failures:\n#{failures}", else: ""}
    """
  end

  defp format_value(value) when is_float(value), do: Float.round(value, 4)
  defp format_value(value), do: value

  defp truncate(nil, _max), do: ""
  defp truncate(value, max) when byte_size(value) <= max, do: value
  defp truncate(value, max), do: String.slice(value, 0, max - 3) <> "..."
end
