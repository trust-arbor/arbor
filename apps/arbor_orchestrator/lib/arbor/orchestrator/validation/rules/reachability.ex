defmodule Arbor.Orchestrator.Validation.Rules.Reachability do
  @moduledoc false
  @behaviour Arbor.Orchestrator.Validation.LintRule

  alias Arbor.Orchestrator.Validation.Diagnostic
  import Arbor.Orchestrator.Validation.Rules.Helpers, only: [find_start_nodes: 1, dfs: 3]

  @impl true
  def name, do: "reachability"

  @impl true
  def validate(graph) do
    case find_start_nodes(graph) do
      [start] ->
        reachable = dfs(graph, MapSet.new(), [start.id])

        graph.nodes
        |> Map.keys()
        |> Enum.reject(&MapSet.member?(reachable, &1))
        |> Enum.map(fn node_id ->
          Diagnostic.error("reachability", "Node is unreachable from start: #{node_id}",
            node_id: node_id
          )
        end)

      _ ->
        []
    end
  end
end
