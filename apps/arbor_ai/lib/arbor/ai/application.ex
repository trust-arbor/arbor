defmodule Arbor.AI.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Propagate API keys from environment to ReqLLM
    propagate_api_keys()

    children =
      if Application.get_env(:arbor_ai, :start_children, true) do
        buffered_store_child() ++
          [
            Arbor.AI.QuotaTracker
          ] ++ budget_tracker_child() ++ usage_stats_child() ++ acp_pool_children()
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

  # BufferedStore for quota + budget persistence.
  # Must start before QuotaTracker and BudgetTracker so they can restore on init.
  defp buffered_store_child do
    backend = Application.get_env(:arbor_ai, :persistence_backend)

    if backend do
      [
        {Arbor.Persistence.BufferedStore,
         name: :arbor_ai_tracking, backend: backend, write_mode: :async, collection: "ai_tracking"}
      ]
    else
      [
        {Arbor.Persistence.BufferedStore,
         name: :arbor_ai_tracking, backend: nil, write_mode: :async, collection: "ai_tracking"}
      ]
    end
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

  # Conditionally add ACP session pool based on config
  defp acp_pool_children do
    if Application.get_env(:arbor_ai, :enable_acp_pool, false) do
      pool_config = Application.get_env(:arbor_ai, :acp_pool_config, [])

      [
        Arbor.AI.AcpPool.Supervisor,
        {Arbor.AI.AcpPool, pool_config}
      ]
    else
      []
    end
  end
end
