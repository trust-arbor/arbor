defmodule Arbor.AI.Router do
  @moduledoc """
  Routes LLM requests to the appropriate backend and model.

  Provides task-aware routing using task classification:

  1. Classifies the prompt into a TaskMeta (risk, complexity, domain, etc.)
  2. Determines the routing tier from the TaskMeta
  3. Gets backend+model candidates for that tier
  4. Filters by trust level, availability (via ProviderCatalog), and quota status
  5. Returns the first available candidate

  ## Configuration

      config :arbor_ai,
        enable_task_routing: true,
        tier_routing: %{
          critical: [{:anthropic, :opus}, {:anthropic, :sonnet}],
          complex: [{:anthropic, :sonnet}, {:openai, :gpt5}],
          ...
        }

  ## Usage

      {:ok, {backend, model}} = Router.route_task("Fix the auth vulnerability")
      {:ok, {backend, model}} = Router.route_task(task_meta)
      {:ok, {:anthropic, "claude-opus-4"}} = Router.route_task(prompt, model: {:anthropic, "claude-opus-4"})
      {:ok, {backend, model}} = Router.route_embedding(prefer: :local)
  """

  alias Arbor.AI.{
    BackendTrust,
    BudgetTracker,
    GraphRouter,
    QuotaTracker,
    RoutingConfig,
    TaskMeta,
    UsageStats
  }

  alias Arbor.Signals

  require Logger

  @type backend :: atom()
  @type model :: atom() | String.t()

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
        try_cloud_fallback()

      [{backend, model} | _rest] ->
        Logger.debug("Router selected embedding provider", backend: backend, model: model)
        {:ok, {backend, model}}
    end
  end

  defp try_cloud_fallback do
    if RoutingConfig.embedding_fallback_to_cloud?() do
      find_available_cloud_provider()
    else
      {:error, :no_embedding_providers}
    end
  end

  defp find_available_cloud_provider do
    cloud_fallback = RoutingConfig.get_embedding_providers(prefer: :cloud)

    case Enum.find(cloud_fallback, fn {backend, _model} -> backend_available?(backend) end) do
      nil -> {:error, :no_embedding_providers}
      {backend, model} -> {:ok, {backend, model}}
    end
  end

  # ===========================================================================
  # Private Functions - Task Routing
  # ===========================================================================

  # Strangler fig: try graph-based routing first, fall back to imperative
  defp do_route_task(task_meta, opts) do
    if graph_routing_enabled?() do
      case GraphRouter.route(task_meta, opts) do
        {:ok, {backend, model}} = result ->
          tier = TaskMeta.tier(task_meta)
          Logger.debug("Router (graph) selected", backend: backend, model: model, tier: tier)
          emit_routing_decision(tier, backend, model, :graph_tier_match, 0)
          result

        {:error, reason} ->
          Logger.debug("Graph routing unavailable, falling back to imperative",
            reason: inspect(reason)
          )

          do_route_task_imperative(task_meta, opts)
      end
    else
      do_route_task_imperative(task_meta, opts)
    end
  end

  defp graph_routing_enabled? do
    Application.get_env(:arbor_ai, :enable_graph_routing, false)
  end

  # Original imperative routing pipeline (fallback)
  defp do_route_task_imperative(task_meta, opts) do
    tier = TaskMeta.tier(task_meta)
    min_trust = Keyword.get(opts, :min_trust, task_meta.min_trust_level)
    exclude = Keyword.get(opts, :exclude, [])

    Logger.debug("Router determining tier", tier: tier, min_trust: min_trust)

    # Get candidates for this tier
    candidates = RoutingConfig.get_tier_backends(tier)
    candidates_count = length(candidates)

    # Apply all filters including budget, then optionally sort by reliability
    filtered_candidates =
      candidates
      |> filter_by_exclusions(exclude)
      |> filter_by_trust(min_trust)
      |> filter_by_sensitivity(opts)
      |> filter_by_availability()
      |> filter_by_quota()
      |> filter_by_budget(tier)
      |> maybe_sort_by_reliability()

    # Select first available
    case List.first(filtered_candidates) do
      nil ->
        # Try fallback chain
        fallback = RoutingConfig.get_fallback_chain(exclude: exclude)

        fallback_candidates =
          fallback
          |> filter_by_trust(min_trust)
          |> filter_by_sensitivity(opts)
          |> filter_by_availability()
          |> filter_by_quota()
          |> filter_by_budget(tier)

        case List.first(fallback_candidates) do
          nil ->
            emit_routing_decision(tier, nil, nil, :no_backends, candidates_count)
            {:error, :no_backends_available}

          {backend, model} ->
            resolved = RoutingConfig.resolve_model(model)
            Logger.debug("Router using fallback", backend: backend, model: resolved)
            emit_routing_decision(tier, backend, resolved, :fallback, candidates_count)
            {:ok, {backend, resolved}}
        end

      {backend, model} ->
        resolved = RoutingConfig.resolve_model(model)
        Logger.debug("Router selected", backend: backend, model: resolved, tier: tier)
        emit_routing_decision(tier, backend, resolved, :tier_match, candidates_count)
        {:ok, {backend, resolved}}
    end
  end

  # ===========================================================================
  # Private Functions - Filtering Pipeline
  # ===========================================================================

  defp filter_by_exclusions(candidates, exclude) do
    Enum.reject(candidates, fn {backend, _model} -> backend in exclude end)
  end

  defp filter_by_trust(candidates, min_trust) do
    Enum.filter(candidates, fn {backend, _model} ->
      BackendTrust.meets_minimum?(backend, min_trust)
    end)
  end

  defp filter_by_sensitivity(candidates, opts) do
    case Keyword.get(opts, :data_sensitivity) do
      nil ->
        candidates

      sensitivity when is_atom(sensitivity) ->
        Enum.filter(candidates, fn {backend, _model} ->
          BackendTrust.can_see?(backend, sensitivity)
        end)
    end
  end

  defp filter_by_availability(candidates) do
    Enum.filter(candidates, fn {backend, _model} ->
      backend_available?(backend)
    end)
  end

  defp filter_by_quota(candidates) do
    Enum.filter(candidates, fn {backend, _model} ->
      QuotaTracker.available?(backend)
    end)
  end

  @doc false
  # Budget-aware filtering - critical tasks bypass constraints
  def filter_by_budget(candidates, tier) do
    cond do
      # Critical tasks ignore budget constraints
      tier == :critical ->
        candidates

      # Over budget: only free backends for non-critical tasks
      BudgetTracker.over_budget?() ->
        free_only =
          Enum.filter(candidates, fn {backend, _model} ->
            BudgetTracker.free_backend?(backend)
          end)

        if free_only == [] do
          Logger.warning("Over budget and no free backends available")
        end

        free_only

      # Low budget: sort free first, allow paid as fallback
      BudgetTracker.should_prefer_free?() ->
        sort_free_first(candidates)

      # Normal budget: no filtering
      true ->
        candidates
    end
  end

  defp sort_free_first(candidates) do
    {free, paid} =
      Enum.split_with(candidates, fn {backend, _model} ->
        BudgetTracker.free_backend?(backend)
      end)

    free ++ paid
  end

  @doc false
  # Sort candidates by reliability (success rate) when enabled
  def maybe_sort_by_reliability(candidates) do
    if reliability_routing_enabled?() and UsageStats.started?() do
      Enum.sort_by(candidates, fn {backend, model} ->
        # Use negative success rate for descending order
        -UsageStats.success_rate(backend, RoutingConfig.resolve_model(model))
      end)
    else
      # Preserve config order when disabled
      candidates
    end
  end

  defp reliability_routing_enabled? do
    Application.get_env(:arbor_ai, :enable_reliability_routing, false)
  end

  defp backend_available?(backend) do
    provider_str = backend_to_provider(backend)

    # Check via ProviderCatalog (runtime bridge — orchestrator is Standalone)
    if Code.ensure_loaded?(Arbor.Orchestrator.UnifiedLLM.ProviderCatalog) do
      catalog = apply(Arbor.Orchestrator.UnifiedLLM.ProviderCatalog, :all, [[]])
      Enum.any?(catalog, fn entry -> entry.provider == provider_str and entry.available? end)
    else
      # Orchestrator not loaded — assume available
      true
    end
  rescue
    _ -> true
  catch
    :exit, _ -> true
  end

  # Map tier routing backend atoms to orchestrator provider strings
  defp backend_to_provider(:anthropic), do: "anthropic"
  defp backend_to_provider(:openai), do: "openai"
  defp backend_to_provider(:gemini), do: "gemini"
  defp backend_to_provider(:opencode), do: "opencode_cli"
  defp backend_to_provider(:qwen), do: "openai"
  defp backend_to_provider(:lmstudio), do: "lm_studio"
  defp backend_to_provider(:ollama), do: "ollama"
  defp backend_to_provider(other), do: Atom.to_string(other)

  # ===========================================================================
  # Private Functions - Signal Emissions
  # ===========================================================================

  defp emit_routing_decision(tier, backend, model, reason, alternatives_count) do
    verbosity = signal_verbosity()

    # Only emit for :normal or :debug verbosity
    if verbosity in [:normal, :debug] do
      Signals.emit(:ai, :routing_decision, %{
        task_tier: tier,
        selected_backend: backend,
        selected_model: model,
        reason: reason,
        alternatives_considered: alternatives_count
      })
    end
  end

  defp signal_verbosity do
    Application.get_env(:arbor_ai, :signal_verbosity, :normal)
  end
end
