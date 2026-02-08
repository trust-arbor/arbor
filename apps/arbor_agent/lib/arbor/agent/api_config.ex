defmodule Arbor.Agent.APIConfig do
  @moduledoc """
  Tiered configuration resolution for API agents.

  Resolution order (later wins):
  1. Global defaults from `config :arbor_agent, :api_defaults`
  2. Per-model overrides from `config :arbor_dashboard, :chat_models`
  3. Per-instance overrides from opts passed to `APIAgent.start_link/1`

  ## Examples

      # Resolve with model-specific overrides
      config = APIConfig.resolve(model_id: "arcee-ai/trinity-large-preview:free")
      config.max_tokens  #=> 32_768 (from per-model override)

      # Resolve with agent-level override on top
      config = APIConfig.resolve(model_id: "arcee-ai/trinity-large-preview:free", max_tokens: 65_536)
      config.max_tokens  #=> 65_536 (agent-level wins)
  """

  @global_defaults %{
    max_tokens: 16_384,
    temperature: 0.7,
    max_turns: 10,
    heartbeat_enabled: true,
    heartbeat_interval_ms: 10_000
  }

  @configurable_keys [
    :max_tokens,
    :temperature,
    :max_turns,
    :heartbeat_enabled,
    :heartbeat_interval_ms
  ]

  @doc """
  Resolve full agent configuration from tiered sources.

  Takes per-instance opts (keyword list) and merges with per-model and global defaults.
  Returns a map with all resolved config values.
  """
  @spec resolve(keyword()) :: map()
  def resolve(opts \\ []) do
    global = global_defaults()
    model_overrides = get_model_overrides(Keyword.get(opts, :model_id))

    agent_overrides =
      opts
      |> Keyword.take(@configurable_keys)
      |> Map.new()

    global
    |> Map.merge(model_overrides)
    |> Map.merge(agent_overrides)
  end

  @doc """
  Get global defaults merged with config.exs overrides.
  """
  @spec global_defaults() :: map()
  def global_defaults do
    app_config =
      Application.get_env(:arbor_agent, :api_defaults, [])
      |> Map.new()

    Map.merge(@global_defaults, app_config)
  end

  @doc """
  Get per-model config overrides for the given model ID.

  Looks up the model in `config :arbor_dashboard, :chat_models` and
  extracts configurable fields.
  """
  @spec get_model_overrides(String.t() | nil) :: map()
  def get_model_overrides(nil), do: %{}

  def get_model_overrides(model_id) do
    models = Application.get_env(:arbor_dashboard, :chat_models, [])

    case Enum.find(models, &(&1[:id] == model_id)) do
      nil ->
        %{}

      model ->
        model
        |> Map.take(@configurable_keys)
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()
    end
  end
end
