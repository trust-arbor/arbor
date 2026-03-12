defmodule Arbor.Common.CapabilityResolver do
  @moduledoc """
  Public facade for unified capability discovery and execution.

  Provides a single entry point for agents to search across all registered
  capability providers (skills, actions, pipelines, etc.) with trust-gated
  visibility and tiered resolution.

  ## Tiered Resolution

  - **Tier 1** (always): ETS keyword search via CapabilityIndex (<1ms)
  - **Tier 2** (if Tier 1 < threshold): Semantic search via SkillLibrary hybrid_search (~50ms)
  - **Tier 3** (future): JIT composition from existing capabilities

  ## Usage

      # Search for capabilities
      results = CapabilityResolver.search("email triage", trust_tier: :established)

      # Get best match
      {:ok, match} = CapabilityResolver.best_match("file read", trust_tier: :trusted)

      # Search and execute in one call
      {:ok, result} = CapabilityResolver.resolve_and_execute("read file", %{path: "foo.ex"})
  """

  alias Arbor.Common.CapabilityIndex
  alias Arbor.Contracts.{CapabilityDescriptor, CapabilityMatch}

  require Logger

  # Score threshold for Tier 1 sufficiency — if best score >= this, skip Tier 2
  @tier1_threshold 0.8
  # Score threshold for Tier 2 sufficiency
  @tier2_threshold 0.6

  @doc """
  Search for capabilities matching a query with tiered resolution.

  Starts with fast keyword search (Tier 1). If the best score is below
  the threshold, escalates to semantic search (Tier 2) and merges results.

  ## Options

  - `:trust_tier` — only return capabilities visible at this tier
  - `:limit` — maximum results (default: 5)
  - `:kind` — filter by capability kind
  - `:tier` — force a specific resolution tier (1 or 2, default: auto)
  """
  @spec search(String.t(), keyword()) :: [CapabilityMatch.t()]
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)
    forced_tier = Keyword.get(opts, :tier)

    # Tier 1: keyword search
    tier1_results = tier1_search(query, opts)

    cond do
      forced_tier == 1 ->
        Enum.take(tier1_results, limit)

      forced_tier == 2 ->
        tier2_results = tier2_search(query, opts)
        merge_results(tier1_results, tier2_results) |> Enum.take(limit)

      tier1_sufficient?(tier1_results) ->
        Enum.take(tier1_results, limit)

      true ->
        tier2_results = tier2_search(query, opts)
        merge_results(tier1_results, tier2_results) |> Enum.take(limit)
    end
  end

  @doc """
  Return the single best matching capability, or error if none found.

  ## Options

  Same as `search/2`.
  """
  @spec best_match(String.t(), keyword()) :: {:ok, CapabilityMatch.t()} | {:error, :no_match}
  def best_match(query, opts \\ []) do
    case search(query, Keyword.put(opts, :limit, 1)) do
      [match | _] -> {:ok, match}
      [] -> {:error, :no_match}
    end
  end

  @doc """
  Search for a capability and execute it in one call.

  Finds the best match, then delegates execution to the capability's provider.

  ## Options

  - `:trust_tier` — trust tier for discovery
  - `:context` — execution context passed to the provider
  - `:min_score` — minimum score to accept (default: 0.5)
  """
  @spec resolve_and_execute(String.t(), map(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def resolve_and_execute(query, input, opts \\ []) do
    min_score = Keyword.get(opts, :min_score, 0.5)

    case best_match(query, opts) do
      {:ok, %CapabilityMatch{score: score}} when score < min_score ->
        {:error, :low_confidence}

      {:ok, %CapabilityMatch{descriptor: descriptor}} ->
        execute_capability(descriptor, input, opts)

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Execute a specific capability by its descriptor.

  Delegates to the provider's execute/3 callback.
  """
  @spec execute(CapabilityDescriptor.t(), map(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def execute(%CapabilityDescriptor{} = descriptor, input, opts \\ []) do
    execute_capability(descriptor, input, opts)
  end

  @doc """
  Get configuration for tier thresholds.
  """
  def tier1_threshold, do: config(:tier1_threshold, @tier1_threshold)
  def tier2_threshold, do: config(:tier2_threshold, @tier2_threshold)

  ## Tier Implementations

  defp tier1_search(query, opts) do
    # Increase internal limit to allow merging with tier 2
    internal_limit = Keyword.get(opts, :limit, 5) * 2
    CapabilityIndex.search(query, Keyword.put(opts, :limit, internal_limit))
  end

  defp tier2_search(query, opts) do
    # Tier 2: semantic search via SkillLibrary hybrid search
    # Only available if SkillLibrary is running
    if skill_library_available?() do
      trust_tier = Keyword.get(opts, :trust_tier)
      limit = Keyword.get(opts, :limit, 5) * 2

      try do
        Arbor.Common.SkillLibrary.hybrid_search(query, limit: limit)
        |> Enum.map(fn skill ->
          descriptor =
            Arbor.Common.CapabilityProviders.SkillProvider.skill_to_descriptor(skill)

          %CapabilityMatch{descriptor: descriptor, score: 0.7, tier: 2}
        end)
        |> Enum.filter(fn match ->
          trust_tier == nil or
            trust_visible?(match.descriptor.trust_required, trust_tier)
        end)
      rescue
        e ->
          Logger.debug("[CapabilityResolver] Tier 2 search failed: #{Exception.message(e)}")
          []
      end
    else
      []
    end
  end

  defp tier1_sufficient?(results) do
    case results do
      [%CapabilityMatch{score: score} | _] when score >= @tier1_threshold -> true
      _ -> false
    end
  end

  # Merge tier 1 and tier 2 results, deduplicating by capability ID.
  # Tier 1 results take precedence (they have more accurate scores).
  defp merge_results(tier1, tier2) do
    tier1_ids = MapSet.new(tier1, fn %{descriptor: d} -> d.id end)

    new_from_tier2 =
      Enum.reject(tier2, fn %{descriptor: d} -> MapSet.member?(tier1_ids, d.id) end)

    (tier1 ++ new_from_tier2)
    |> Enum.sort_by(fn %{score: s} -> s end, :desc)
  end

  defp execute_capability(%CapabilityDescriptor{} = descriptor, input, opts) do
    provider = descriptor.provider

    if Code.ensure_loaded?(provider) and function_exported?(provider, :execute, 3) do
      provider.execute(descriptor.id, input, opts)
    else
      {:error, {:provider_unavailable, provider}}
    end
  end

  defp skill_library_available? do
    Process.whereis(Arbor.Common.SkillLibrary) != nil
  end

  # Trust tier ordering for visibility checks
  @trust_order [:new, :provisional, :established, :trusted, :full_partner, :system]

  defp trust_visible?(_required, nil), do: true

  defp trust_visible?(required, agent_tier) do
    trust_level(required) <= trust_level(agent_tier)
  end

  defp trust_level(tier) do
    Enum.find_index(@trust_order, &(&1 == tier)) || 0
  end

  defp config(key, default) do
    Application.get_env(:arbor_common, :capability_resolver, [])
    |> Keyword.get(key, default)
  end
end
