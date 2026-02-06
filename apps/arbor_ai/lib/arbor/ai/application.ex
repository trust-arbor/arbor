defmodule Arbor.AI.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Propagate API keys from environment to ReqLLM
    propagate_api_keys()

    children =
      if Application.get_env(:arbor_ai, :start_children, true) do
        [
          Arbor.AI.BackendRegistry,
          Arbor.AI.QuotaTracker,
          Arbor.AI.SessionRegistry
        ] ++ budget_tracker_child() ++ usage_stats_child()
      else
        []
      end

    opts = [strategy: :one_for_one, name: Arbor.AI.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Propagate API keys from environment variables to ReqLLM
  defp propagate_api_keys do
    key_mappings = [
      {"OPENROUTER_API_KEY", :openrouter_api_key},
      {"ANTHROPIC_API_KEY", :anthropic_api_key},
      {"OPENAI_API_KEY", :openai_api_key},
      {"GOOGLE_API_KEY", :google_api_key},
      {"GEMINI_API_KEY", :google_api_key}
    ]

    Enum.each(key_mappings, fn {env_var, config_key} ->
      case System.get_env(env_var) do
        nil -> :ok
        "" -> :ok
        value -> ReqLLM.put_key(config_key, value)
      end
    end)
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
