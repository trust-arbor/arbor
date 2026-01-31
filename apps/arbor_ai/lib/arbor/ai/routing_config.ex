defmodule Arbor.AI.RoutingConfig do
  @moduledoc """
  Centralized configuration for tier-based routing and model name resolution.

  This module provides:
  - Per-tier backend+model candidates
  - Model name resolution (atom shorthands → version strings)
  - Embedding provider configuration
  - Fallback chain configuration

  ## Configuration

      config :arbor_ai,
        tier_routing: %{
          critical: [{:anthropic, :opus}, {:anthropic, :sonnet}],
          complex: [{:anthropic, :sonnet}, {:openai, :gpt5}, {:gemini, :auto}],
          moderate: [{:gemini, :auto}, {:anthropic, :sonnet}],
          simple: [{:opencode, :grok}, {:qwen, :qwen_code}, {:gemini, :auto}],
          trivial: [{:opencode, :grok}, {:qwen, :qwen_code}]
        },

        embedding_routing: %{
          preferred: :local,
          providers: [
            {:ollama, "nomic-embed-text"},
            {:lmstudio, "text-embedding"},
            {:openai, "text-embedding-3-small"}
          ],
          fallback_to_cloud: true
        }

  ## Model Resolution

  Atom shorthands are resolved to current version strings at runtime:

      RoutingConfig.resolve_model(:sonnet)
      #=> "claude-sonnet-4-20250514"

      RoutingConfig.resolve_model("gpt-4-turbo")
      #=> "gpt-4-turbo"  # explicit strings pass through unchanged
  """

  @type tier :: :critical | :complex | :moderate | :simple | :trivial
  @type backend :: atom()
  @type model :: atom() | String.t()
  @type prefer :: :local | :cloud | :auto

  # ===========================================================================
  # Model Name Resolution
  # ===========================================================================

  # Model shorthands → current version strings
  # This is the single place to update when new model versions ship
  @model_versions %{
    # Anthropic
    opus: "claude-opus-4-20250514",
    sonnet: "claude-sonnet-4-20250514",
    haiku: "claude-haiku-3-5-20241022",
    # OpenAI
    gpt5: "gpt-5",
    gpt4: "gpt-4-turbo",
    gpt4o: "gpt-4o",
    # Google
    gemini_pro: "gemini-pro",
    gemini_flash: "gemini-flash",
    # OpenCode/Grok
    grok: "grok-beta",
    # Qwen
    qwen_code: "qwen-coder",
    # Generic
    auto: "auto"
  }

  # ===========================================================================
  # Tier Configuration
  # ===========================================================================

  @default_tier_routing %{
    critical: [{:anthropic, :opus}, {:anthropic, :sonnet}],
    complex: [{:anthropic, :sonnet}, {:openai, :gpt5}, {:gemini, :auto}],
    moderate: [{:gemini, :auto}, {:anthropic, :sonnet}, {:openai, :gpt5}],
    simple: [{:opencode, :grok}, {:qwen, :qwen_code}, {:gemini, :auto}],
    trivial: [{:opencode, :grok}, {:qwen, :qwen_code}]
  }

  @default_embedding_config %{
    preferred: :local,
    providers: [
      {:ollama, "nomic-embed-text"},
      {:lmstudio, "text-embedding"},
      {:openai, "text-embedding-3-small"}
    ],
    fallback_to_cloud: true
  }

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Get backend+model candidates for a routing tier.

  Returns a list of `{backend, model}` tuples in preference order.
  Models are returned as atoms; use `resolve_model/1` to get version strings.

  ## Examples

      iex> RoutingConfig.get_tier_backends(:critical)
      [{:anthropic, :opus}, {:anthropic, :sonnet}]

      iex> RoutingConfig.get_tier_backends(:trivial)
      [{:opencode, :grok}, {:qwen, :qwen_code}]
  """
  @spec get_tier_backends(tier()) :: [{backend(), model()}]
  def get_tier_backends(tier) when tier in [:critical, :complex, :moderate, :simple, :trivial] do
    tier_config()
    |> Map.get(tier, [])
  end

  @doc """
  Get fallback chain for when tier candidates are exhausted.

  This is a general fallback chain that can be used when all tier-specific
  backends fail. Ordered by preference.

  ## Options

  - `:exclude` - List of backends to exclude from the fallback chain
  """
  @spec get_fallback_chain(keyword()) :: [{backend(), model()}]
  def get_fallback_chain(opts \\ []) do
    exclude = Keyword.get(opts, :exclude, [])

    # Default fallback: try local first, then progressively less trusted
    fallback = [
      {:lmstudio, :auto},
      {:ollama, :auto},
      {:anthropic, :sonnet},
      {:openai, :gpt4},
      {:gemini, :auto}
    ]

    Enum.reject(fallback, fn {backend, _model} -> backend in exclude end)
  end

  @doc """
  Resolve model shorthand to full version string.

  Atom shorthands (`:sonnet`, `:opus`, etc.) are resolved to their current
  version strings. Explicit strings pass through unchanged.

  ## Examples

      iex> RoutingConfig.resolve_model(:sonnet)
      "claude-sonnet-4-20250514"

      iex> RoutingConfig.resolve_model(:opus)
      "claude-opus-4-20250514"

      iex> RoutingConfig.resolve_model("gpt-4-turbo-preview")
      "gpt-4-turbo-preview"
  """
  @spec resolve_model(atom() | String.t()) :: String.t()
  def resolve_model(model) when is_binary(model), do: model

  def resolve_model(model) when is_atom(model) do
    Map.get(@model_versions, model, Atom.to_string(model))
  end

  @doc """
  Get embedding provider candidates.

  Returns providers in preference order based on the `:prefer` option.

  ## Options

  - `:prefer` - `:local`, `:cloud`, or `:auto` (default: configured preference)

  ## Examples

      iex> RoutingConfig.get_embedding_providers(prefer: :local)
      [{:ollama, "nomic-embed-text"}, {:lmstudio, "text-embedding"}, {:openai, "text-embedding-3-small"}]

      iex> RoutingConfig.get_embedding_providers(prefer: :cloud)
      [{:openai, "text-embedding-3-small"}, {:ollama, "nomic-embed-text"}, {:lmstudio, "text-embedding"}]
  """
  @spec get_embedding_providers(keyword()) :: [{backend(), String.t()}]
  def get_embedding_providers(opts \\ []) do
    config = embedding_config()
    prefer = Keyword.get(opts, :prefer, config.preferred)
    providers = config.providers

    case prefer do
      :local ->
        # Local-first ordering (default)
        providers

      :cloud ->
        # Cloud-first ordering
        sort_cloud_first(providers)

      :auto ->
        # Default preference
        providers
    end
  end

  @doc """
  Check if cloud fallback is enabled for embeddings.
  """
  @spec embedding_fallback_to_cloud?() :: boolean()
  def embedding_fallback_to_cloud? do
    embedding_config().fallback_to_cloud
  end

  @doc """
  Check if task-aware routing is enabled.

  When false, the system should use legacy `select_backend/1` behavior.
  """
  @spec task_routing_enabled?() :: boolean()
  def task_routing_enabled? do
    Application.get_env(:arbor_ai, :enable_task_routing, true)
  end

  @doc """
  Get all model version mappings.

  Useful for debugging and introspection.
  """
  @spec model_versions() :: %{atom() => String.t()}
  def model_versions, do: @model_versions

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp tier_config do
    Application.get_env(:arbor_ai, :tier_routing, @default_tier_routing)
  end

  defp embedding_config do
    default = @default_embedding_config
    config = Application.get_env(:arbor_ai, :embedding_routing, %{})

    %{
      preferred: Map.get(config, :preferred, default.preferred),
      providers: Map.get(config, :providers, default.providers),
      fallback_to_cloud: Map.get(config, :fallback_to_cloud, default.fallback_to_cloud)
    }
  end

  # Determine if a provider is cloud-based
  defp cloud_provider?(backend) do
    backend in [:openai, :anthropic, :gemini, :cohere]
  end

  # Sort providers with cloud-based ones first
  defp sort_cloud_first(providers) do
    {cloud, local} =
      Enum.split_with(providers, fn {backend, _model} -> cloud_provider?(backend) end)

    cloud ++ local
  end
end
