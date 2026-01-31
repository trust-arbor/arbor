defmodule Arbor.AI.Router do
  @moduledoc """
  Routes LLM requests to the appropriate backend and model.

  The router supports two routing modes:

  1. **Legacy routing** (`select_backend/1`): Simple binary choice between `:api` and `:cli`
  2. **Task-aware routing** (`route_task/2`): Tier-based routing using task classification

  ## Task-Aware Routing

  When task-aware routing is enabled (default), the router:
  1. Classifies the prompt into a TaskMeta (risk, complexity, domain, etc.)
  2. Determines the routing tier from the TaskMeta
  3. Gets backend+model candidates for that tier
  4. Filters by trust level, availability, and quota status
  5. Returns the first available candidate

  ## Configuration

      config :arbor_ai,
        # Enable task-aware routing (default: true)
        enable_task_routing: true,

        # Legacy routing
        default_backend: :auto,
        routing_strategy: :cost_optimized,

        # Tier-based routing
        tier_routing: %{
          critical: [{:anthropic, :opus}, {:anthropic, :sonnet}],
          complex: [{:anthropic, :sonnet}, {:openai, :gpt5}],
          ...
        }

  ## Usage

      # Task-aware routing (recommended)
      {:ok, {backend, model}} = Router.route_task("Fix the auth vulnerability")
      {:ok, {backend, model}} = Router.route_task(task_meta)

      # Manual model override (bypasses routing)
      {:ok, {:anthropic, "claude-opus-4"}} = Router.route_task(prompt, model: {:anthropic, "claude-opus-4"})

      # Embedding routing
      {:ok, {backend, model}} = Router.route_embedding(prefer: :local)

      # Legacy routing (backward compatible)
      backend = Router.select_backend(opts)
  """

  alias Arbor.AI.{BackendRegistry, BackendTrust, QuotaTracker, RoutingConfig, TaskMeta}

  require Logger

  @type backend :: atom()
  @type model :: atom() | String.t()
  @type legacy_backend :: :api | :cli
  @type strategy :: :cost_optimized | :quality_first | :cli_only | :api_only

  # ===========================================================================
  # Task-Aware Routing
  # ===========================================================================

  @doc """
  Route a task to an appropriate backend and model.

  Accepts either a prompt string (which gets classified) or a TaskMeta struct.

  ## Options

  - `:model` - Manual override `{backend, model}` - bypasses routing entirely
  - `:min_trust` - Override minimum trust level (default: from TaskMeta)
  - `:exclude` - List of backends to exclude

  ## Returns

  - `{:ok, {backend, model}}` - Selected backend and resolved model string
  - `{:error, :no_backends_available}` - All backends filtered out
  - `{:error, :task_routing_disabled}` - Task routing is disabled in config

  ## Examples

      # Auto-classify and route
      {:ok, {:anthropic, "claude-opus-4-20250514"}} = Router.route_task("Fix auth vulnerability")

      # Route pre-classified task
      meta = TaskMeta.classify("Hello")
      {:ok, {:opencode, "grok-beta"}} = Router.route_task(meta)

      # Manual override
      {:ok, {:anthropic, "claude-custom"}} = Router.route_task(prompt, model: {:anthropic, "claude-custom"})
  """
  @spec route_task(TaskMeta.t() | String.t(), keyword()) ::
          {:ok, {backend(), String.t()}} | {:error, term()}
  def route_task(task_or_prompt, opts \\ [])

  def route_task(prompt, opts) when is_binary(prompt) do
    # Classify the string prompt into TaskMeta
    task_meta = TaskMeta.classify(prompt)
    route_task(task_meta, opts)
  end

  def route_task(%TaskMeta{} = task_meta, opts) when is_list(opts) do
    # Check for manual override first
    case Keyword.get(opts, :model) do
      {backend, model} when is_atom(backend) ->
        resolved = RoutingConfig.resolve_model(model)
        Logger.debug("Router using manual override", backend: backend, model: resolved)
        {:ok, {backend, resolved}}

      nil ->
        # Check if task routing is enabled
        if RoutingConfig.task_routing_enabled?() do
          do_route_task(task_meta, opts)
        else
          {:error, :task_routing_disabled}
        end

      _invalid ->
        {:error, :invalid_model_override}
    end
  end

  @doc """
  Route an embedding request to an appropriate provider.

  ## Options

  - `:prefer` - `:local`, `:cloud`, or `:auto` (default: configured preference)

  ## Returns

  - `{:ok, {backend, model}}` - Selected embedding provider and model
  - `{:error, :no_embedding_providers}` - No providers available

  ## Examples

      # Default (prefers local)
      {:ok, {:ollama, "nomic-embed-text"}} = Router.route_embedding()

      # Prefer cloud
      {:ok, {:openai, "text-embedding-3-small"}} = Router.route_embedding(prefer: :cloud)
  """
  @spec route_embedding(keyword()) :: {:ok, {backend(), String.t()}} | {:error, term()}
  def route_embedding(opts \\ []) do
    providers = RoutingConfig.get_embedding_providers(opts)

    # Filter by availability
    available =
      providers
      |> Enum.filter(fn {backend, _model} ->
        backend_available?(backend)
      end)

    case available do
      [] ->
        # Check if we should fall back to cloud
        if RoutingConfig.embedding_fallback_to_cloud?() do
          # Try cloud providers even if not preferred
          cloud_fallback = RoutingConfig.get_embedding_providers(prefer: :cloud)

          case Enum.find(cloud_fallback, fn {backend, _model} -> backend_available?(backend) end) do
            nil -> {:error, :no_embedding_providers}
            {backend, model} -> {:ok, {backend, model}}
          end
        else
          {:error, :no_embedding_providers}
        end

      [{backend, model} | _rest] ->
        Logger.debug("Router selected embedding provider", backend: backend, model: model)
        {:ok, {backend, model}}
    end
  end

  # ===========================================================================
  # Legacy Routing (Backward Compatible)
  # ===========================================================================

  @doc """
  Select the appropriate backend for a request (legacy API).

  This is the original routing function that provides binary choice
  between `:api` and `:cli` backends.

  ## Options

  - `:backend` - Explicit backend selection (`:api`, `:cli`, or `:auto`)
  - `:strategy` - Override routing strategy for this request

  ## Returns

  `:api` or `:cli`
  """
  @spec select_backend(keyword()) :: legacy_backend()
  def select_backend(opts \\ []) do
    case Keyword.get(opts, :backend, default_backend()) do
      :api ->
        :api

      :cli ->
        :cli

      :auto ->
        # Use strategy to decide
        strategy = Keyword.get(opts, :strategy, routing_strategy())
        select_by_strategy(strategy, opts)
    end
  end

  @doc """
  Returns true if CLI backends should be tried before API.
  """
  @spec prefer_cli?(keyword()) :: boolean()
  def prefer_cli?(opts \\ []) do
    select_backend(opts) == :cli
  end

  @doc """
  Route and execute a generation request (legacy convenience function).

  This function selects the backend and dispatches to the appropriate
  implementation. For task-aware routing, use `route_task/2` instead.
  """
  @spec route(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def route(prompt, opts \\ []) do
    backend = select_backend(opts)

    Logger.debug("Router selected backend", backend: backend)

    case backend do
      :cli ->
        Arbor.AI.CliImpl.generate_text(prompt, opts)

      :api ->
        # Delegate to the API implementation (ReqLLM path)
        Arbor.AI.generate_text_via_api(prompt, opts)
    end
  end

  # ===========================================================================
  # Private Functions - Task Routing
  # ===========================================================================

  # Extracted from route_task/2 for pattern matching convenience
  defp do_route_task(task_meta, opts) do
    tier = TaskMeta.tier(task_meta)
    min_trust = Keyword.get(opts, :min_trust, task_meta.min_trust_level)
    exclude = Keyword.get(opts, :exclude, [])

    Logger.debug("Router determining tier", tier: tier, min_trust: min_trust)

    # Get candidates for this tier
    candidates = RoutingConfig.get_tier_backends(tier)

    # Filter and select
    case select_candidate(candidates, min_trust, exclude) do
      nil ->
        # Try fallback chain
        fallback = RoutingConfig.get_fallback_chain(exclude: exclude)

        case select_candidate(fallback, min_trust, []) do
          nil ->
            {:error, :no_backends_available}

          {backend, model} ->
            resolved = RoutingConfig.resolve_model(model)
            Logger.debug("Router using fallback", backend: backend, model: resolved)
            {:ok, {backend, resolved}}
        end

      {backend, model} ->
        resolved = RoutingConfig.resolve_model(model)
        Logger.debug("Router selected", backend: backend, model: resolved, tier: tier)
        {:ok, {backend, resolved}}
    end
  end

  defp select_candidate(candidates, min_trust, exclude) do
    candidates
    |> Enum.reject(fn {backend, _model} -> backend in exclude end)
    |> Enum.filter(fn {backend, _model} ->
      BackendTrust.meets_minimum?(backend, min_trust) and
        backend_available?(backend) and
        QuotaTracker.available?(backend)
    end)
    |> List.first()
  end

  defp backend_available?(backend) do
    # Map routing backend names to BackendRegistry names
    registry_name = backend_to_registry_name(backend)
    BackendRegistry.available?(registry_name) == :available
  end

  # Map tier config backend names to BackendRegistry names
  defp backend_to_registry_name(:anthropic), do: :claude_cli
  defp backend_to_registry_name(:openai), do: :codex_cli
  defp backend_to_registry_name(:gemini), do: :gemini_cli
  defp backend_to_registry_name(:qwen), do: :qwen_cli
  defp backend_to_registry_name(:opencode), do: :opencode_cli
  defp backend_to_registry_name(:lmstudio), do: :lmstudio
  defp backend_to_registry_name(:ollama), do: :lmstudio
  defp backend_to_registry_name(other), do: other

  # ===========================================================================
  # Private Functions - Legacy Routing
  # ===========================================================================

  defp select_by_strategy(:cost_optimized, _opts) do
    # Prefer CLI (free) over API (paid)
    :cli
  end

  defp select_by_strategy(:quality_first, opts) do
    # Use API for important requests, CLI for bulk/simple
    if Keyword.get(opts, :important, false) do
      :api
    else
      :cli
    end
  end

  defp select_by_strategy(:cli_only, _opts) do
    :cli
  end

  defp select_by_strategy(:api_only, _opts) do
    :api
  end

  defp select_by_strategy(_unknown, _opts) do
    # Default to cost-optimized
    :cli
  end

  defp default_backend do
    Application.get_env(:arbor_ai, :default_backend, :auto)
  end

  defp routing_strategy do
    Application.get_env(:arbor_ai, :routing_strategy, :cost_optimized)
  end
end
