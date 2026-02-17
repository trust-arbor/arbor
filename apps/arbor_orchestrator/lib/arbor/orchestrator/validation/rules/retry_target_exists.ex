defmodule Arbor.Orchestrator.Validation.Rules.RetryTargetExists do
  @moduledoc false
  @behaviour Arbor.Orchestrator.Validation.LintRule

  alias Arbor.Orchestrator.Validation.Diagnostic

  @impl true
  def name, do: "retry_target_exists"

  @impl true
  def validate(graph) do
    graph_warnings =
      ["retry_target", "fallback_retry_target"]
      |> Enum.flat_map(fn key ->
        target = Map.get(graph.attrs, key)

        if target in [nil, ""] or Map.has_key?(graph.nodes, target) do
          []
        else
          [
            Diagnostic.warning(
              "retry_target_exists",
              "Graph #{key} points to unknown node: #{target}"
            )
          ]
        end
      end)

    node_warnings =
      graph.nodes
      |> Map.values()
      |> Enum.flat_map(fn node ->
        ["retry_target", "fallback_retry_target"]
        |> Enum.flat_map(fn key ->
          target = Map.get(node.attrs, key)

          if target in [nil, ""] or Map.has_key?(graph.nodes, target) do
            []
          else
            [
              Diagnostic.warning(
                "retry_target_exists",
                "Node #{node.id} #{key} points to unknown node: #{target}",
                node_id: node.id
              )
            ]
          end
        end)
      end)

    graph_warnings ++ node_warnings
  end
end
