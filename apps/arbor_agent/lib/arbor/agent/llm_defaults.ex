defmodule Arbor.Agent.LLMDefaults do
  @moduledoc """
  Centralized LLM model/provider resolution for agents.

  Resolution order (first non-nil wins):
  1. Agent-level config (per-agent opts or `:arbor_agent` app env)
  2. System default (`Arbor.AI.Config` via runtime bridge)
  3. Hardcoded last resort (free OpenRouter model)

  This module bridges the hierarchy gap — `arbor_agent` (Level 2) cannot
  compile-time depend on `arbor_ai` (Standalone), so we use
  `Code.ensure_loaded?` + `apply/3` at runtime.
  """

  @last_resort_model "arcee-ai/trinity-large-preview:free"
  @last_resort_provider :openrouter

  @doc """
  Resolve the default model for an agent.

  Checks agent-level config keys first, then system default, then last resort.

  ## Options

  - `:agent_model_key` — app env key to check first (e.g. `:heartbeat_model`)
  - `:fallback_key` — secondary app env key (e.g. `:mind_model` falls back to `:heartbeat_model`)
  """
  @spec default_model(keyword()) :: String.t()
  def default_model(opts \\ []) do
    agent_key = Keyword.get(opts, :agent_model_key)
    fallback_key = Keyword.get(opts, :fallback_key)

    agent_value(agent_key) ||
      agent_value(fallback_key) ||
      system_default_model() ||
      @last_resort_model
  end

  @doc """
  Resolve the default provider for an agent.

  ## Options

  - `:agent_provider_key` — app env key to check first (e.g. `:heartbeat_provider`)
  - `:fallback_key` — secondary app env key
  """
  @spec default_provider(keyword()) :: atom()
  def default_provider(opts \\ []) do
    agent_key = Keyword.get(opts, :agent_provider_key)
    fallback_key = Keyword.get(opts, :fallback_key)

    agent_value(agent_key) ||
      agent_value(fallback_key) ||
      system_default_provider() ||
      @last_resort_provider
  end

  @doc """
  The absolute last-resort model. Used when nothing else is configured.
  """
  @spec last_resort_model() :: String.t()
  def last_resort_model, do: @last_resort_model

  @doc """
  The absolute last-resort provider.
  """
  @spec last_resort_provider() :: atom()
  def last_resort_provider, do: @last_resort_provider

  # -- Private --

  defp agent_value(nil), do: nil
  defp agent_value(key), do: Application.get_env(:arbor_agent, key)

  # Runtime bridge to Arbor.AI.Config (Standalone app, can't compile-time depend)
  defp system_default_model do
    if Code.ensure_loaded?(Arbor.AI.Config) and
         function_exported?(Arbor.AI.Config, :default_model, 0) do
      apply(Arbor.AI.Config, :default_model, [])
    end
  end

  defp system_default_provider do
    if Code.ensure_loaded?(Arbor.AI.Config) and
         function_exported?(Arbor.AI.Config, :default_provider, 0) do
      apply(Arbor.AI.Config, :default_provider, [])
    end
  end
end
