defmodule Arbor.Agent.ConfigCore do
  @moduledoc """
  Pure CRC module for agent configuration operations.

  Resolves model profiles, builds session configs, and formats configuration
  for display. Works with the AgentSpec struct for construction and the
  Config domain struct for runtime state.

  Most construction logic lives in `Arbor.Agent.Spec.new/1`. This module
  provides additional pure operations on resolved configurations.

  ## CRC Pattern

  - **Construct**: `resolve_model_profile/1` — model string → full profile
  - **Reduce**: `update_model/3`, `update_tools/2` — config state transitions
  - **Convert**: `show_config/1`, `for_llm/1` — formatted output
  """

  alias Arbor.Contracts.Agent.Config

  # ===========================================================================
  # Construct
  # ===========================================================================

  @doc """
  Resolve a full model profile from a model ID string.

  Returns a map with context_window, effective_window, max_output_tokens,
  cost_per_token, and family. Uses ModelProfile for known models, falls
  back to defaults for unknown.
  """
  @spec resolve_model_profile(String.t() | nil) :: map()
  def resolve_model_profile(nil), do: default_model_profile()

  def resolve_model_profile(model_id) when is_binary(model_id) do
    model_profile = Arbor.Common.ModelProfile

    if Code.ensure_loaded?(model_profile) do
      case apply(model_profile, :get, [model_id]) do
        nil -> default_model_profile()
        profile -> profile
      end
    else
      default_model_profile()
    end
  end

  @doc """
  Build a Config struct from an AgentSpec.
  """
  @spec from_spec(map()) :: Config.t()
  def from_spec(spec) do
    %Config{
      provider: spec.provider,
      model: spec.model,
      model_profile: resolve_model_profile(spec.model),
      system_prompt: spec.system_prompt,
      generation_params: %{},
      tools: spec.tools,
      heartbeat: spec.heartbeat,
      execution_mode: spec.execution_mode,
      auto_start: spec.auto_start
    }
  end

  # ===========================================================================
  # Reduce
  # ===========================================================================

  @doc "Update the model on a Config struct."
  @spec update_model(Config.t(), atom(), String.t()) :: Config.t()
  def update_model(%Config{} = config, provider, model) do
    %{config |
      provider: provider,
      model: model,
      model_profile: resolve_model_profile(model)
    }
  end

  @doc "Update the tool list."
  @spec update_tools(Config.t(), [String.t()]) :: Config.t()
  def update_tools(%Config{} = config, tools) when is_list(tools) do
    %{config | tools: tools}
  end

  @doc "Update generation parameters."
  @spec update_generation_params(Config.t(), map()) :: Config.t()
  def update_generation_params(%Config{} = config, params) when is_map(params) do
    %{config | generation_params: Map.merge(config.generation_params, params)}
  end

  # ===========================================================================
  # Convert
  # ===========================================================================

  @doc "Format configuration for dashboard display."
  @spec show_config(Config.t()) :: map()
  def show_config(%Config{} = config) do
    %{
      provider: config.provider,
      model: config.model,
      context_window: get_in(config.model_profile, [:context_size]) || "unknown",
      effective_window: get_in(config.model_profile, [:effective_window]) || "unknown",
      max_output: get_in(config.model_profile, [:max_output_tokens]) || "unknown",
      tool_count: length(config.tools || []),
      heartbeat_enabled: config.heartbeat[:enabled] || false,
      execution_mode: config.execution_mode
    }
  end

  @doc "Format configuration for LLM call (provider + model + params)."
  @spec for_llm(Config.t()) :: map()
  def for_llm(%Config{} = config) do
    %{
      "llm_provider" => to_string(config.provider || ""),
      "llm_model" => config.model,
      "system_prompt" => config.system_prompt
    }
    |> Map.merge(
      config.generation_params
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Map.new()
    )
  end

  @doc "Format model info as a display string."
  @spec format_model(Config.t()) :: String.t()
  def format_model(%Config{provider: nil}), do: "not configured"
  def format_model(%Config{provider: provider, model: model}) do
    "#{provider}:#{model}"
  end

  # ===========================================================================
  # Private
  # ===========================================================================

  defp default_model_profile do
    %{
      context_size: 128_000,
      effective_window_pct: 0.75,
      effective_window: 96_000,
      max_output_tokens: 4096,
      family: :unknown
    }
  end
end
