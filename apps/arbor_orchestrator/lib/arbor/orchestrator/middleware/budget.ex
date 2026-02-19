defmodule Arbor.Orchestrator.Middleware.Budget do
  @moduledoc """
  Mandatory middleware that checks and deducts resource budgets.

  Bridges to `Arbor.Orchestrator.BudgetTracker` when available. Checks budget
  before node execution and records token usage after.

  No-op when no budget tracker is configured.

  ## Token Assigns

    - `:budget_tracker` — pid or module of the budget tracker
    - `:skip_budget_check` — set to true to bypass this middleware
  """

  use Arbor.Orchestrator.Middleware

  alias Arbor.Orchestrator.Engine.Outcome

  @impl true
  def before_node(token) do
    cond do
      Map.get(token.assigns, :skip_budget_check, false) ->
        token

      not has_budget_tracker?(token) ->
        token

      true ->
        check_budget(token)
    end
  end

  @impl true
  def after_node(token) do
    cond do
      Map.get(token.assigns, :skip_budget_check, false) ->
        token

      not has_budget_tracker?(token) ->
        token

      true ->
        record_usage(token)
    end
  end

  defp check_budget(token) do
    tracker = Map.get(token.assigns, :budget_tracker)

    if budget_tracker_available?(tracker) do
      case apply_tracker(tracker, :check_budget, []) do
        :ok ->
          token

        {:over_budget, reason} ->
          Token.halt(
            token,
            "Budget exceeded: #{reason}",
            %Outcome{status: :fail, failure_reason: "Budget exceeded: #{reason}"}
          )

        _ ->
          token
      end
    else
      token
    end
  end

  defp record_usage(token) do
    tracker = Map.get(token.assigns, :budget_tracker)

    if token.outcome && budget_tracker_available?(tracker) do
      # Extract token usage from context updates if available
      updates = token.outcome.context_updates || %{}

      usage = %{
        node_id: token.node.id,
        tokens: Map.get(updates, "llm.tokens_used"),
        cost: Map.get(updates, "llm.cost")
      }

      try do
        apply_tracker(tracker, :record_usage, [usage])
      rescue
        _ -> :ok
      end
    end

    token
  end

  defp has_budget_tracker?(token) do
    Map.get(token.assigns, :budget_tracker) != nil
  end

  defp budget_tracker_available?(nil), do: false

  defp budget_tracker_available?(tracker) when is_atom(tracker) do
    Code.ensure_loaded?(tracker) and function_exported?(tracker, :check_budget, 0)
  end

  defp budget_tracker_available?(tracker) when is_pid(tracker), do: Process.alive?(tracker)
  defp budget_tracker_available?(_), do: false

  defp apply_tracker(tracker, fun, args) when is_atom(tracker) do
    apply(tracker, fun, args)
  end

  defp apply_tracker(tracker, fun, args) when is_pid(tracker) do
    GenServer.call(tracker, {fun, args})
  end
end
