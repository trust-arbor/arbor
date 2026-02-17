defmodule Arbor.Orchestrator.Validation.Rules.GoalGateRetry do
  @moduledoc false
  @behaviour Arbor.Orchestrator.Validation.LintRule

  alias Arbor.Orchestrator.Validation.Diagnostic
  import Arbor.Orchestrator.Validation.Rules.Helpers, only: [truthy?: 1]

  @impl true
  def name, do: "goal_gate_has_retry"

  @impl true
  def validate(graph) do
    graph.nodes
    |> Map.values()
    |> Enum.flat_map(fn node ->
      if truthy?(Map.get(node.attrs, "goal_gate", false)) and
           Map.get(node.attrs, "retry_target") in [nil, ""] and
           Map.get(node.attrs, "fallback_retry_target") in [nil, ""] do
        [
          Diagnostic.warning(
            "goal_gate_has_retry",
            "Goal gate node should define retry_target or fallback_retry_target",
            node_id: node.id
          )
        ]
      else
        []
      end
    end)
  end
end
