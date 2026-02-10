defmodule Arbor.Orchestrator.Handlers.EvalAggregateHandler do
  @moduledoc """
  Handler that computes metrics over evaluation results.

  Node attributes:
    - `source` — node ID whose results to aggregate (auto-detected if omitted)
    - `metrics` — comma-separated metric names (default: "accuracy,mean_score")
    - `threshold` — minimum value for the primary metric to pass (optional)
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Eval.Metrics

  @impl true
  def execute(node, context, graph, _opts) do
    try do
      source = Map.get(node.attrs, "source") || find_eval_run_node(graph, node)
      results = Context.get(context, "eval.results.#{source}", [])

      unless is_list(results) and results != [] do
        raise "eval.aggregate: no results found at 'eval.results.#{source}'"
      end

      metric_names = parse_csv(Map.get(node.attrs, "metrics", "accuracy,mean_score"))

      metrics =
        Map.new(metric_names, fn name ->
          {name, Metrics.compute(name, results, [])}
        end)

      threshold = parse_float(Map.get(node.attrs, "threshold"))
      primary_metric = List.first(metric_names)
      primary_value = Map.get(metrics, primary_metric, 0.0)

      status =
        if threshold && primary_value < threshold do
          :fail
        else
          :success
        end

      metrics_str =
        metrics
        |> Enum.map(fn {k, v} -> "#{k}=#{Float.round(v, 4)}" end)
        |> Enum.join(", ")

      notes =
        if threshold do
          "#{metrics_str} (threshold: #{primary_metric} >= #{threshold})"
        else
          metrics_str
        end

      %Outcome{
        status: status,
        notes: notes,
        failure_reason:
          if(status == :fail,
            do: "#{primary_metric}=#{Float.round(primary_value, 4)} < threshold #{threshold}"
          ),
        context_updates: %{
          "eval.metrics.#{node.id}" => metrics
        }
      }
    rescue
      e ->
        %Outcome{
          status: :fail,
          failure_reason: "eval.aggregate error: #{Exception.message(e)}"
        }
    end
  end

  @impl true
  def idempotency, do: :read_only

  defp find_eval_run_node(graph, current_node) do
    # Walk backwards from current node to find the nearest eval.run node
    graph
    |> Arbor.Orchestrator.Graph.incoming_edges(current_node.id)
    |> Enum.map(& &1.from)
    |> Enum.find(fn node_id ->
      case Map.get(graph.nodes, node_id) do
        nil -> false
        node -> Map.get(node.attrs, "type") == "eval.run"
      end
    end)
    |> Kernel.||("unknown")
  end

  defp parse_csv(nil), do: ["accuracy", "mean_score"]
  defp parse_csv(""), do: ["accuracy", "mean_score"]

  defp parse_csv(str) do
    str |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

  defp parse_float(nil), do: nil
  defp parse_float(val) when is_float(val), do: val
  defp parse_float(val) when is_integer(val), do: val / 1.0

  defp parse_float(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_float(_), do: nil
end
