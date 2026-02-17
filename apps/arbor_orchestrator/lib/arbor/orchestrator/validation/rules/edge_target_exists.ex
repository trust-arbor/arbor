defmodule Arbor.Orchestrator.Validation.Rules.EdgeTargetExists do
  @moduledoc false
  @behaviour Arbor.Orchestrator.Validation.LintRule

  alias Arbor.Orchestrator.Validation.Diagnostic

  @impl true
  def name, do: "edge_target_exists"

  @impl true
  def validate(graph) do
    graph.edges
    |> Enum.filter(fn edge -> not Map.has_key?(graph.nodes, edge.to) end)
    |> Enum.map(fn edge ->
      Diagnostic.error(
        "edge_target_exists",
        "Edge target does not exist: #{edge.to}",
        edge: {edge.from, edge.to}
      )
    end)
  end
end
