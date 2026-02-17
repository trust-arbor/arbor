defmodule Arbor.Orchestrator.Validation.Rules.ConditionSyntax do
  @moduledoc false
  @behaviour Arbor.Orchestrator.Validation.LintRule

  alias Arbor.Orchestrator.Engine.Condition
  alias Arbor.Orchestrator.Validation.Diagnostic

  @impl true
  def name, do: "condition_syntax"

  @impl true
  def validate(graph) do
    graph.edges
    |> Enum.flat_map(fn edge ->
      condition = Map.get(edge.attrs, "condition", "")

      if condition not in [nil, ""] and not Condition.valid_syntax?(condition) do
        [
          Diagnostic.error(
            "condition_syntax",
            "Invalid edge condition syntax: #{condition}",
            edge: {edge.from, edge.to}
          )
        ]
      else
        []
      end
    end)
  end
end
