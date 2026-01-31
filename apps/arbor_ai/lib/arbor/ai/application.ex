defmodule Arbor.AI.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # Backend availability registry with ETS caching
        Arbor.AI.BackendRegistry,

        # Quota tracking for CLI backends
        Arbor.AI.QuotaTracker,

        # Session tracking for multi-turn conversations
        Arbor.AI.SessionRegistry
      ] ++ budget_tracker_child() ++ usage_stats_child()

    opts = [strategy: :one_for_one, name: Arbor.AI.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Conditionally add BudgetTracker based on config
  defp budget_tracker_child do
    if Application.get_env(:arbor_ai, :enable_budget_tracking, true) do
      [Arbor.AI.BudgetTracker]
    else
      []
    end
  end

  # Conditionally add UsageStats based on config
  defp usage_stats_child do
    if Application.get_env(:arbor_ai, :enable_stats_tracking, true) do
      [Arbor.AI.UsageStats]
    else
      []
    end
  end
end
