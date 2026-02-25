defmodule Arbor.AI.GraphRouter do
  @moduledoc """
  Routes LLM requests using a DOT graph executed by the orchestrator engine.

  This module wraps `Engine.run/2` with pre-computed filter context, replacing
  the imperative filter pipeline in `Router.do_route_task/2`. The routing graph
  (`llm-routing.dot`) is parsed once and cached in persistent_term.

  ## How It Works

  1. Pre-compute all filter flags (availability, trust, quota, budget) by
     querying BackendRegistry, BackendTrust, QuotaTracker, and BudgetTracker
  2. Pass flags as `initial_values` to `Engine.run/2` — the handler does zero I/O
  3. Engine executes the routing graph: tier dispatch → candidate selection → fallback
  4. Extract `selected_backend` and `selected_model` from the final context

  ## Context Protocol

  The routing graph handler (`routing.select`) expects flat string context:

  - `tier` — routing tier string ("critical", "complex", etc.)
  - `budget_status` — "normal", "low", or "over"
  - `exclude` — comma-separated backend names to skip
  - `avail_<backend>` — "true" if backend is available
  - `trust_<backend>` — "true" if backend meets minimum trust
  - `quota_<backend>` — "true" if backend has quota remaining
  - `free_<backend>` — "true" if backend is free-tier
  """

  alias Arbor.AI.{
    BackendTrust,
    BudgetTracker,
    QuotaTracker,
    RoutingConfig,
    TaskMeta
  }

  require Logger

  @graph_key {__MODULE__, :routing_graph}
  @dot_path "apps/arbor_orchestrator/specs/pipelines/llm-routing.dot"

  # All backends that may appear in routing candidates
  @all_backends ~w(anthropic openai gemini opencode qwen lmstudio ollama)

  # Backend name → ProviderCatalog provider string mapping
  @backend_provider_names %{
    "anthropic" => "anthropic",
    "openai" => "openai",
    "gemini" => "gemini",
    "qwen" => "openai",
    "opencode" => "opencode_cli",
    "lmstudio" => "lm_studio",
    "ollama" => "ollama"
  }

  @doc """
  Check if the graph routing engine is available.

  Returns true if the orchestrator modules are loaded and the routing
  graph can be parsed.
  """
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(Arbor.Orchestrator.Engine) and
      Code.ensure_loaded?(Arbor.Orchestrator.Dot.Parser) and
      get_routing_graph() != nil
  end

  @doc """
  Route a task using the DOT routing graph.

  Pre-computes all filter data, runs the graph via the orchestrator engine,
  and returns the selected backend+model pair.

  ## Returns

  - `{:ok, {backend_atom, model_string}}` on success
  - `{:error, reason}` on failure
  """
  @spec route(TaskMeta.t(), keyword()) ::
          {:ok, {atom(), String.t()}} | {:error, term()}
  def route(%TaskMeta{} = task_meta, opts \\ []) do
    graph = get_routing_graph()

    if graph == nil do
      {:error, :graph_unavailable}
    else
      tier = TaskMeta.tier(task_meta)
      min_trust = Keyword.get(opts, :min_trust, task_meta.min_trust_level)
      exclude = Keyword.get(opts, :exclude, [])

      context = build_routing_context(tier, min_trust, exclude)
      run_graph(graph, context)
    end
  end

  @doc """
  Invalidate the cached routing graph, forcing a re-parse on next use.
  """
  @spec reload_graph!() :: :ok
  def reload_graph! do
    :persistent_term.erase(@graph_key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # ---------------------------------------------------------------------------
  # Private — Context Building
  # ---------------------------------------------------------------------------

  defp build_routing_context(tier, min_trust, exclude) do
    context = %{
      "tier" => Atom.to_string(tier),
      "budget_status" => budget_status(),
      "exclude" => Enum.map_join(exclude, ",", &Atom.to_string/1)
    }

    # Pre-compute available providers via ProviderCatalog (runtime bridge)
    available_set = fetch_available_providers()

    # Pre-compute per-backend flags
    Enum.reduce(@all_backends, context, fn backend, acc ->
      provider_str = Map.get(@backend_provider_names, backend, backend)

      acc
      |> Map.put(
        "avail_#{backend}",
        bool(MapSet.member?(available_set, provider_str))
      )
      |> Map.put(
        "trust_#{backend}",
        bool(BackendTrust.meets_minimum?(String.to_existing_atom(backend), min_trust))
      )
      |> Map.put(
        "quota_#{backend}",
        bool(QuotaTracker.available?(String.to_existing_atom(backend)))
      )
      |> Map.put(
        "free_#{backend}",
        bool(BudgetTracker.free_backend?(String.to_existing_atom(backend)))
      )
    end)
  end

  # Fetch set of available provider strings from ProviderCatalog via runtime bridge
  defp fetch_available_providers do
    if Code.ensure_loaded?(Arbor.Orchestrator.UnifiedLLM.ProviderCatalog) do
      apply(Arbor.Orchestrator.UnifiedLLM.ProviderCatalog, :available, [[]])
      |> Enum.map(fn {provider, _caps} -> provider end)
      |> MapSet.new()
    else
      # Orchestrator not loaded — assume all available
      MapSet.new(@all_backends)
    end
  rescue
    _ -> MapSet.new(@all_backends)
  catch
    :exit, _ -> MapSet.new(@all_backends)
  end

  defp budget_status do
    cond do
      BudgetTracker.over_budget?() -> "over"
      BudgetTracker.should_prefer_free?() -> "low"
      true -> "normal"
    end
  end

  defp bool(true), do: "true"
  defp bool(false), do: "false"
  defp bool(_), do: "false"

  # ---------------------------------------------------------------------------
  # Private — Graph Execution
  # ---------------------------------------------------------------------------

  defp run_graph(graph, context) do
    engine = Arbor.Orchestrator.Engine

    opts = [
      initial_values: context,
      max_steps: 20,
      logs_root: Path.join(System.tmp_dir!(), "arbor_routing")
    ]

    case apply(engine, :run, [graph, opts]) do
      {:ok, %{context: final_context}} ->
        extract_result(final_context)

      {:error, reason} ->
        Logger.warning("Graph routing failed", reason: inspect(reason))
        {:error, {:graph_routing_failed, reason}}
    end
  end

  defp extract_result(context) do
    backend = Map.get(context, "selected_backend")
    model = Map.get(context, "selected_model")

    if backend && model do
      backend_atom = String.to_existing_atom(backend)
      resolved = RoutingConfig.resolve_model(model)
      {:ok, {backend_atom, resolved}}
    else
      {:error, :no_backends_available}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — Graph Caching
  # ---------------------------------------------------------------------------

  defp get_routing_graph do
    case :persistent_term.get(@graph_key, :not_loaded) do
      :not_loaded -> load_and_cache_graph()
      graph -> graph
    end
  end

  defp load_and_cache_graph do
    dot_path = resolve_dot_path()

    with {:ok, source} <- File.read(dot_path),
         {:ok, graph} <- parse_dot(source) do
      :persistent_term.put(@graph_key, graph)
      graph
    else
      error ->
        Logger.warning("Failed to load routing graph", path: dot_path, error: inspect(error))
        nil
    end
  end

  defp resolve_dot_path do
    # Try relative to project root first, then absolute
    cond do
      File.exists?(@dot_path) -> @dot_path
      File.exists?(Path.join(File.cwd!(), @dot_path)) -> Path.join(File.cwd!(), @dot_path)
      true -> @dot_path
    end
  end

  defp parse_dot(source) do
    parser = Arbor.Orchestrator.Dot.Parser
    apply(parser, :parse, [source])
  end
end
