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

  # ===========================================================================
  # Provider usage ledger
  # ===========================================================================

  @provider_usage_ledger_target_keys MapSet.new([
                                       :name,
                                       :backend,
                                       :opts,
                                       "name",
                                       "backend",
                                       "opts"
                                     ])

  @doc """
  Closed production target for the durable provider usage ledger.

  Returns `{:error, :provider_usage_ledger_target_unset}` when no target is
  configured. Production never silently falls back to ETS, Agent, BufferedStore,
  or another volatile/cache-acknowledged backend.
  """
  @spec provider_usage_ledger_target() ::
          {:ok, %{name: atom(), backend: module(), opts: keyword()}}
          | {:error, :provider_usage_ledger_target_unset | :invalid_provider_usage_ledger_target}
  def provider_usage_ledger_target do
    provider_usage_ledger_target_from(Application.get_env(@app, :provider_usage_ledger_target))
  end

  @doc """
  Normalize a raw provider usage ledger target source.

  Accepts the same shapes as application config. `nil` is the explicit absent
  source and fails closed without reading or mutating Application env. Tests use
  this seam to prove missing-target behavior without global config side effects.
  """
  @spec provider_usage_ledger_target_from(term()) ::
          {:ok, %{name: atom(), backend: module(), opts: keyword()}}
          | {:error, :provider_usage_ledger_target_unset | :invalid_provider_usage_ledger_target}
  def provider_usage_ledger_target_from(nil), do: {:error, :provider_usage_ledger_target_unset}

  def provider_usage_ledger_target_from(raw), do: normalize_provider_usage_ledger_target(raw)

  @doc """
  Validate a closed provider usage ledger target.

  Accepts a map or keyword list carrying `:name` (atom store name),
  `:backend` (module), and optional `:opts` (keyword list). Unknown keys and
  ambiguous atom/string duplicates are rejected.
  """
  @spec normalize_provider_usage_ledger_target(term()) ::
          {:ok, %{name: atom(), backend: module(), opts: keyword()}}
          | {:error, :invalid_provider_usage_ledger_target}
  def normalize_provider_usage_ledger_target(target) when is_list(target) do
    if keyword_list?(target) do
      normalize_provider_usage_ledger_target(Map.new(target))
    else
      {:error, :invalid_provider_usage_ledger_target}
    end
  end

  def normalize_provider_usage_ledger_target(target)
      when is_map(target) and not is_struct(target) do
    with :ok <- ensure_closed_target_keys(target),
         {:ok, name} <- fetch_closed_target_field(target, :name),
         {:ok, backend} <- fetch_closed_target_field(target, :backend),
         {:ok, opts} <- fetch_closed_target_opts(target),
         true <- valid_target_name?(name),
         true <- valid_target_backend?(backend),
         true <- keyword_list?(opts) do
      {:ok, %{name: name, backend: backend, opts: opts}}
    else
      _ -> {:error, :invalid_provider_usage_ledger_target}
    end
  end

  def normalize_provider_usage_ledger_target(_target),
    do: {:error, :invalid_provider_usage_ledger_target}

  defp ensure_closed_target_keys(target) do
    if Enum.all?(Map.keys(target), &MapSet.member?(@provider_usage_ledger_target_keys, &1)) do
      :ok
    else
      :error
    end
  end

  defp fetch_closed_target_field(target, atom_key) do
    string_key = Atom.to_string(atom_key)
    has_atom? = Map.has_key?(target, atom_key)
    has_string? = Map.has_key?(target, string_key)

    cond do
      has_atom? and has_string? -> :error
      has_atom? -> {:ok, Map.fetch!(target, atom_key)}
      has_string? -> {:ok, Map.fetch!(target, string_key)}
      true -> :error
    end
  end

  defp fetch_closed_target_opts(target) do
    has_atom? = Map.has_key?(target, :opts)
    has_string? = Map.has_key?(target, "opts")

    cond do
      has_atom? and has_string? -> :error
      has_atom? -> {:ok, Map.fetch!(target, :opts)}
      has_string? -> {:ok, Map.fetch!(target, "opts")}
      true -> {:ok, []}
    end
  end

  defp valid_target_name?(name) when is_atom(name) and not is_nil(name), do: true
  defp valid_target_name?(_name), do: false

  defp valid_target_backend?(backend) when is_atom(backend) and not is_nil(backend), do: true
  defp valid_target_backend?(_backend), do: false

  defp keyword_list?([]), do: true
  defp keyword_list?([{key, _value} | rest]) when is_atom(key), do: keyword_list?(rest)
  defp keyword_list?(_), do: false
end
