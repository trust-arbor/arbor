defmodule Arbor.Orchestrator.Handlers.EvalReportHandler do
  @moduledoc """
  Handler that formats and outputs evaluation results.

  Node attributes:
    - `format` — output format: "terminal" (default), "json", "markdown"
    - `output` — file path for report output (optional, stdout if omitted)
    - `source` — node ID of eval.run results (auto-detected if omitted)
    - `metrics_source` — node ID of eval.aggregate metrics (auto-detected if omitted)
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Graph

  @impl true
  def execute(node, context, graph, opts) do
    format = Map.get(node.attrs, "format", "terminal")
    source = Map.get(node.attrs, "source") || find_source(graph, node, "eval.run")

    metrics_source =
      Map.get(node.attrs, "metrics_source") || find_source(graph, node, "eval.aggregate")

    results = Context.get(context, "eval.results.#{source}", [])
    metrics = Context.get(context, "eval.metrics.#{metrics_source}", %{})

    report = format_report(results, metrics, format)

    case Map.get(node.attrs, "output") do
      nil ->
        # Store in context
        %Outcome{
          status: :success,
          notes: report,
          context_updates: %{
            "eval.report.#{node.id}" => report,
            "eval.report.#{node.id}.format" => format
          }
        }

      output_path ->
        workdir = Context.get(context, "workdir") || Keyword.get(opts, :workdir, ".")

        resolved =
          if Path.type(output_path) == :absolute,
            do: output_path,
            else: Path.join(workdir, output_path)

        File.mkdir_p!(Path.dirname(resolved))
        File.write!(resolved, report)

        %Outcome{
          status: :success,
          notes: "Report written to #{resolved}",
          context_updates: %{
            "eval.report.#{node.id}" => report,
            "eval.report.#{node.id}.path" => resolved
          }
        }
    end
  rescue
    e ->
      %Outcome{
        status: :fail,
        failure_reason: "eval.report error: #{Exception.message(e)}"
      }
  end

  @impl true
  def idempotency, do: :idempotent_with_key

  defp format_report(results, metrics, "json") do
    Jason.encode!(%{"results" => results, "metrics" => metrics}, pretty: true)
  end

  defp format_report(results, metrics, "markdown") do
    total = length(results)
    passed = Enum.count(results, & &1["passed"])
    failed = total - passed

    metrics_section =
      Enum.map_join(metrics, "\n", fn {k, v} -> "| #{k} | #{Float.round(v, 4)} |" end)

    failures =
      results
      |> Enum.reject(& &1["passed"])
      |> Enum.take(5)
      |> Enum.map_join("\n", fn r ->
        scores = r["scores"] || []
        score_str = Enum.map_join(scores, ", ", fn s -> "#{s.score}" end)

        "- **#{r["id"]}**: expected=`#{truncate(r["expected"], 60)}` actual=`#{truncate(to_string(r["actual"]), 60)}` scores=[#{score_str}]"
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

  defp format_report(results, metrics, _terminal) do
    total = length(results)
    passed = Enum.count(results, & &1["passed"])

    metrics_lines =
      Enum.map_join(metrics, "\n", fn {k, v} -> "  #{k}: #{Float.round(v, 4)}" end)

    failures =
      results
      |> Enum.reject(& &1["passed"])
      |> Enum.take(3)
      |> Enum.map_join("\n", fn r ->
        "  - #{r["id"]}: expected=#{truncate(r["expected"], 40)} actual=#{truncate(to_string(r["actual"]), 40)}"
      end)

    """
    === Evaluation Report ===
    Samples: #{total} | Passed: #{passed} | Failed: #{total - passed}

    Metrics:
    #{metrics_lines}
    #{if failures != "", do: "\nTop Failures:\n#{failures}", else: ""}
    """
  end

  defp find_source(graph, current_node, type_prefix) do
    graph
    |> Graph.incoming_edges(current_node.id)
    |> Enum.map(& &1.from)
    |> Enum.find(fn node_id ->
      case Map.get(graph.nodes, node_id) do
        nil -> false
        node -> String.starts_with?(Map.get(node.attrs, "type", ""), type_prefix)
      end
    end)
    |> Kernel.||("unknown")
  end

  defp truncate(nil, _), do: ""
  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max - 3) <> "..."
end
