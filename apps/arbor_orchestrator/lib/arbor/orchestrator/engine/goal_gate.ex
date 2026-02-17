defmodule Arbor.Orchestrator.Engine.GoalGate do
  @moduledoc """
  Goal gate retry resolution for the pipeline engine.

  Goal gates are nodes with `goal_gate="true"` that act as quality checkpoints.
  When a goal gate fails (status not in `:success` or `:partial_success`),
  the engine attempts to retry from a target node, following this priority:

  1. Node-level `retry_target` attribute
  2. Node-level `fallback_retry_target` attribute
  3. Graph-level `retry_target` attribute
  4. Graph-level `fallback_retry_target` attribute

  If no valid retry target is found, the pipeline fails with
  `:goal_gate_unsatisfied_no_retry_target`.
  """

  import Arbor.Orchestrator.Validation.Rules.Helpers, only: [truthy?: 1]

  alias Arbor.Orchestrator.Engine.Router

  @doc """
  Resolves a retry target for any failed goal gate in the outcomes.

  Returns:
  - `{:ok, nil}` — no goal gate failed
  - `{:ok, target_id}` — retry from this node
  - `{:error, :goal_gate_unsatisfied_no_retry_target}` — gate failed, no retry path
  """
  @spec resolve_retry_target(map(), map()) ::
          {:ok, nil} | {:ok, String.t()} | {:error, :goal_gate_unsatisfied_no_retry_target}
  def resolve_retry_target(graph, outcomes) do
    case find_failed_gate(graph, outcomes) do
      nil ->
        {:ok, nil}

      failed_gate ->
        case resolve_targets(failed_gate, graph) do
          nil -> {:error, :goal_gate_unsatisfied_no_retry_target}
          target -> {:ok, target}
        end
    end
  end

  @doc """
  Finds the first failed goal gate node in the outcomes.

  A goal gate is failed when its outcome status is not `:success` or `:partial_success`.
  """
  @spec find_failed_gate(map(), map()) :: map() | nil
  def find_failed_gate(graph, outcomes) do
    Enum.find_value(outcomes, fn {node_id, outcome} ->
      node = Map.get(graph.nodes, node_id)

      if node != nil and truthy?(Map.get(node.attrs, "goal_gate", false)) and
           outcome.status not in [:success, :partial_success] do
        node
      else
        nil
      end
    end)
  end

  @doc """
  Resolves the retry target for a failed goal gate node.

  Checks node-level targets first, then graph-level fallbacks.
  Returns the first valid target node ID, or nil if none found.
  """
  @spec resolve_targets(map(), map()) :: String.t() | nil
  def resolve_targets(node, graph) do
    [
      Map.get(node.attrs, "retry_target"),
      Map.get(node.attrs, "fallback_retry_target"),
      Map.get(graph.attrs, "retry_target"),
      Map.get(graph.attrs, "fallback_retry_target")
    ]
    |> Enum.find(&Router.valid_target?(graph, &1))
  end
end
