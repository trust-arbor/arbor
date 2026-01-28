defmodule Arbor.AI.Config do
  @moduledoc """
  Configuration for Arbor.AI.

  Provides application-level configuration for LLM defaults and routing.

  ## Configuration

      config :arbor_ai,
        # API settings
        default_provider: :anthropic,
        default_model: "claude-sonnet-4-5-20250514",
        timeout: 60_000,

        # Routing settings
        default_backend: :auto,                    # :api, :cli, or :auto
        routing_strategy: :cost_optimized,         # :cost_optimized, :quality_first, :cli_only, :api_only

        # CLI fallback chain - order matters
        cli_fallback_chain: [:anthropic, :openai, :gemini, :lmstudio],

        # CLI timeouts (longer for interactive agents)
        cli_backend_timeout: 300_000               # 5 minutes
  """

  @app :arbor_ai

  # Default fallback chain for CLI backends
  @default_cli_chain [:anthropic, :openai, :gemini, :lmstudio]

  # ===========================================================================
  # API Settings
  # ===========================================================================

  @doc """
  Default LLM provider for API calls.

  Default: `:anthropic`
  """
  @spec default_provider() :: atom()
  def default_provider do
    Application.get_env(@app, :default_provider, :anthropic)
  end

  @doc """
  Default model for the default provider.

  Default: `"claude-sonnet-4-5-20250514"`
  """
  @spec default_model() :: String.t()
  def default_model do
    Application.get_env(@app, :default_model, "claude-sonnet-4-5-20250514")
  end

  @doc """
  Default timeout for API LLM requests in milliseconds.

  Default: `60_000` (60 seconds)
  """
  @spec timeout() :: pos_integer()
  def timeout do
    Application.get_env(@app, :timeout, 60_000)
  end

  @doc """
  Maximum retries for transient LLM errors.

  Default: `2`
  """
  @spec max_retries() :: non_neg_integer()
  def max_retries do
    Application.get_env(@app, :max_retries, 2)
  end

  # ===========================================================================
  # Routing Settings
  # ===========================================================================

  @doc """
  Default backend for LLM requests.

  - `:api` - Use API backend (ReqLLM, paid)
  - `:cli` - Use CLI backend (subscriptions, "free")
  - `:auto` - Use routing strategy to decide (default)

  Default: `:auto`
  """
  @spec default_backend() :: :api | :cli | :auto
  def default_backend do
    Application.get_env(@app, :default_backend, :auto)
  end

  @doc """
  Routing strategy when backend is `:auto`.

  - `:cost_optimized` - Prefer CLI over API (default)
  - `:quality_first` - Use API for important requests
  - `:cli_only` - Only use CLI backends
  - `:api_only` - Only use API backends

  Default: `:cost_optimized`
  """
  @spec routing_strategy() :: atom()
  def routing_strategy do
    Application.get_env(@app, :routing_strategy, :cost_optimized)
  end

  # ===========================================================================
  # CLI Settings
  # ===========================================================================

  @doc """
  Fallback chain for CLI backends.

  When a CLI backend fails or is quota-exhausted, the next one in the chain
  is tried. Providers are tried in order until one succeeds.

  Available providers: `:anthropic`, `:openai`, `:gemini`, `:qwen`, `:opencode`, `:lmstudio`

  Default: `[:anthropic, :openai, :gemini, :lmstudio]`
  """
  @spec cli_fallback_chain() :: [atom()]
  def cli_fallback_chain do
    Application.get_env(@app, :cli_fallback_chain, @default_cli_chain)
  end

  @doc """
  Timeout for CLI backend operations in milliseconds.

  CLI agents can take longer than API calls, so this defaults higher.

  Default: `300_000` (5 minutes)
  """
  @spec cli_backend_timeout() :: pos_integer()
  def cli_backend_timeout do
    Application.get_env(@app, :cli_backend_timeout, 300_000)
  end

  @doc """
  TTL for backend registry cache in milliseconds.

  Default: `300_000` (5 minutes)
  """
  @spec backend_registry_ttl() :: pos_integer()
  def backend_registry_ttl do
    Application.get_env(@app, :backend_registry_ttl_ms, 300_000)
  end
end
