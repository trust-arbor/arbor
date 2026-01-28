defmodule Arbor.Consensus.Analytics do
  @moduledoc """
  Analytics and observability for the consensus system.

  Provides query functions to understand proposer behavior, feedback effectiveness,
  and revision patterns without requiring additional schema fields.

  ## Revision Tracking

  Proposers can optionally include `parent_proposal_id` in proposal metadata
  to explicitly link revisions:

      Proposal.new(%{
        proposer: "agent_123",
        change_type: :code_modification,
        description: "Fix security concern from previous attempt",
        metadata: %{parent_proposal_id: "prop_abc123"}
      })

  If not provided, revisions can still be detected via time-based heuristics
  (same proposer + similar change_type within a time window).

  ## Usage

      # Get all proposals from a proposer with their outcomes
      Analytics.proposer_history("agent_123", coordinator: coord)

      # Find potential revision chains
      Analytics.revision_chains("agent_123", coordinator: coord)

      # Find concerns that keep appearing
      Analytics.repeated_concerns("agent_123", coordinator: coord)

      # Get feedback size for a decision
      Analytics.feedback_size(decision)

      # Overall stats for a proposer
      Analytics.proposer_stats("agent_123", coordinator: coord)
  """

  alias Arbor.Consensus.{Coordinator, EventStore}
  alias Arbor.Contracts.Consensus.{CouncilDecision, Proposal}

  @type proposer_id :: String.t()
  @type opts :: keyword()

  # Default time window for detecting implicit revision chains (30 minutes)
  @default_revision_window_ms 30 * 60 * 1000

  # ============================================================================
  # Proposer History
  # ============================================================================

  @doc """
  Get all proposals from a proposer with their decisions.

  Returns a list of `{proposal, decision | nil}` tuples, ordered by creation time.

  ## Options

  - `:coordinator` - Coordinator server (default: Coordinator)
  - `:since` - Only include proposals after this DateTime
  - `:limit` - Maximum number of proposals to return
  """
  @spec proposer_history(proposer_id(), opts()) :: [{Proposal.t(), CouncilDecision.t() | nil}]
  def proposer_history(proposer_id, opts \\ []) do
    coordinator = Keyword.get(opts, :coordinator, Coordinator)
    since = Keyword.get(opts, :since)
    limit = Keyword.get(opts, :limit)

    proposals =
      coordinator
      |> Coordinator.list_proposals()
      |> Enum.filter(&(&1.proposer == proposer_id))
      |> maybe_filter_since(since)
      |> Enum.sort_by(& &1.created_at, DateTime)
      |> maybe_take(limit)

    Enum.map(proposals, fn proposal ->
      decision =
        case Coordinator.get_decision(proposal.id, coordinator) do
          {:ok, d} -> d
          _ -> nil
        end

      {proposal, decision}
    end)
  end

  # ============================================================================
  # Revision Chains
  # ============================================================================

  @doc """
  Find revision chains for a proposer.

  A revision chain is a sequence of proposals that appear to be iterations
  on the same change. Detection methods:

  1. Explicit: `metadata.parent_proposal_id` links proposals
  2. Implicit: Same proposer + change_type within time window

  Returns a list of chains, where each chain is a list of proposals
  ordered from original to latest revision.

  ## Options

  - `:coordinator` - Coordinator server (default: Coordinator)
  - `:revision_window_ms` - Time window for implicit detection (default: 30 min)
  """
  @spec revision_chains(proposer_id(), opts()) :: [[Proposal.t()]]
  def revision_chains(proposer_id, opts \\ []) do
    coordinator = Keyword.get(opts, :coordinator, Coordinator)
    window_ms = Keyword.get(opts, :revision_window_ms, @default_revision_window_ms)

    proposals =
      coordinator
      |> Coordinator.list_proposals()
      |> Enum.filter(&(&1.proposer == proposer_id))
      |> Enum.sort_by(& &1.created_at, DateTime)

    # Build explicit chains first (via parent_proposal_id)
    {explicit_chains, unchained} = build_explicit_chains(proposals)

    # Then detect implicit chains from remaining proposals
    implicit_chains = build_implicit_chains(unchained, window_ms)

    # Combine and filter out single-proposal "chains"
    (explicit_chains ++ implicit_chains)
    |> Enum.filter(&(length(&1) > 1))
  end

  @doc """
  Get the revision depth for a proposer.

  Returns the maximum number of revision attempts for any single change.
  High values may indicate feedback isn't landing effectively.
  """
  @spec max_revision_depth(proposer_id(), opts()) :: non_neg_integer()
  def max_revision_depth(proposer_id, opts \\ []) do
    proposer_id
    |> revision_chains(opts)
    |> Enum.map(&length/1)
    |> Enum.max(fn -> 0 end)
  end

  # ============================================================================
  # Concern Analysis
  # ============================================================================

  @doc """
  Find concerns that appear repeatedly across a proposer's proposals.

  This can indicate that feedback isn't being addressed, or that the
  proposer has a systematic blind spot.

  Returns a list of `{concern, count, proposal_ids}` tuples, sorted by count.

  ## Options

  - `:coordinator` - Coordinator server (default: Coordinator)
  - `:min_occurrences` - Minimum times a concern must appear (default: 2)
  """
  @spec repeated_concerns(proposer_id(), opts()) :: [{String.t(), pos_integer(), [String.t()]}]
  def repeated_concerns(proposer_id, opts \\ []) do
    coordinator = Keyword.get(opts, :coordinator, Coordinator)
    min_occurrences = Keyword.get(opts, :min_occurrences, 2)

    history = proposer_history(proposer_id, coordinator: coordinator)

    # Collect all concerns with their proposal IDs
    concern_map =
      Enum.reduce(history, %{}, fn {proposal, decision}, acc ->
        concerns = extract_concerns(decision)

        Enum.reduce(concerns, acc, fn concern, inner_acc ->
          Map.update(inner_acc, concern, [proposal.id], &[proposal.id | &1])
        end)
      end)

    # Filter and format
    concern_map
    |> Enum.filter(fn {_concern, proposal_ids} -> length(proposal_ids) >= min_occurrences end)
    |> Enum.map(fn {concern, proposal_ids} -> {concern, length(proposal_ids), proposal_ids} end)
    |> Enum.sort_by(fn {_concern, count, _ids} -> -count end)
  end

  # ============================================================================
  # Feedback Size
  # ============================================================================

  @doc """
  Estimate the size of feedback in a decision.

  Returns a map with character counts and rough token estimates.
  Useful for detecting when feedback might exceed context limits.

  ## Token Estimation

  Uses a rough estimate of 4 characters per token, which is typical
  for English text. Actual token counts vary by model.
  """
  @spec feedback_size(CouncilDecision.t()) :: map()
  def feedback_size(%CouncilDecision{} = decision) do
    # Aggregate all text content
    concerns_text = Enum.join(decision.primary_concerns, " ")

    reasoning_text = Enum.map_join(decision.evaluations, " ", & &1.reasoning)

    recommendations_text =
      decision.evaluations
      |> Enum.flat_map(& &1.recommendations)
      |> Enum.join(" ")

    all_concerns_text =
      decision.evaluations
      |> Enum.flat_map(& &1.concerns)
      |> Enum.join(" ")

    total_chars =
      String.length(concerns_text) +
        String.length(reasoning_text) +
        String.length(recommendations_text) +
        String.length(all_concerns_text)

    %{
      primary_concerns_chars: String.length(concerns_text),
      reasoning_chars: String.length(reasoning_text),
      recommendations_chars: String.length(recommendations_text),
      all_concerns_chars: String.length(all_concerns_text),
      total_chars: total_chars,
      estimated_tokens: div(total_chars, 4),
      evaluation_count: length(decision.evaluations)
    }
  end

  @doc """
  Check if feedback size exceeds a threshold.

  ## Options

  - `:max_tokens` - Maximum estimated tokens (default: 4000)
  """
  @spec feedback_exceeds_limit?(CouncilDecision.t(), opts()) :: boolean()
  def feedback_exceeds_limit?(decision, opts \\ []) do
    max_tokens = Keyword.get(opts, :max_tokens, 4000)
    size = feedback_size(decision)
    size.estimated_tokens > max_tokens
  end

  # ============================================================================
  # Proposer Stats
  # ============================================================================

  @doc """
  Get aggregate statistics for a proposer.

  Useful for understanding proposer behavior and identifying potential issues.
  """
  @spec proposer_stats(proposer_id(), opts()) :: map()
  def proposer_stats(proposer_id, opts \\ []) do
    coordinator = Keyword.get(opts, :coordinator, Coordinator)

    history = proposer_history(proposer_id, coordinator: coordinator)
    chains = revision_chains(proposer_id, opts)
    concerns = repeated_concerns(proposer_id, opts)

    # Count outcomes
    outcomes =
      Enum.reduce(history, %{approved: 0, rejected: 0, deadlock: 0, pending: 0}, fn
        {proposal, nil}, acc ->
          Map.update!(acc, :pending, &(&1 + 1))

        {_proposal, decision}, acc ->
          Map.update!(acc, decision.decision, &(&1 + 1))
      end)

    # Calculate feedback sizes
    feedback_sizes =
      history
      |> Enum.filter(fn {_, decision} -> decision != nil end)
      |> Enum.map(fn {_, decision} -> feedback_size(decision).estimated_tokens end)

    avg_feedback_tokens =
      if feedback_sizes == [] do
        0
      else
        div(Enum.sum(feedback_sizes), length(feedback_sizes))
      end

    %{
      proposer_id: proposer_id,
      total_proposals: length(history),
      outcomes: outcomes,
      approval_rate: safe_ratio(outcomes.approved, length(history)),
      revision_chains: length(chains),
      max_revision_depth: Enum.map(chains, &length/1) |> Enum.max(fn -> 0 end),
      repeated_concern_count: length(concerns),
      top_repeated_concerns: Enum.take(concerns, 3) |> Enum.map(fn {c, n, _} -> {c, n} end),
      avg_feedback_tokens: avg_feedback_tokens,
      max_feedback_tokens: Enum.max(feedback_sizes, fn -> 0 end)
    }
  end

  # ============================================================================
  # Event-based Queries
  # ============================================================================

  @doc """
  Get events for a proposer from the EventStore.

  ## Options

  - `:event_store` - EventStore server (default: EventStore)
  - `:event_type` - Filter by event type
  - `:since` - Events after this DateTime
  - `:limit` - Maximum events to return
  """
  @spec proposer_events(proposer_id(), opts()) :: [map()]
  def proposer_events(proposer_id, opts \\ []) do
    event_store = Keyword.get(opts, :event_store, EventStore)

    filters =
      opts
      |> Keyword.take([:event_type, :since, :limit])
      |> Keyword.put(:agent_id, proposer_id)

    EventStore.query(filters, event_store)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp maybe_filter_since(proposals, nil), do: proposals

  defp maybe_filter_since(proposals, since) do
    Enum.filter(proposals, &(DateTime.compare(&1.created_at, since) in [:gt, :eq]))
  end

  defp maybe_take(proposals, nil), do: proposals
  defp maybe_take(proposals, limit), do: Enum.take(proposals, limit)

  defp extract_concerns(nil), do: []

  defp extract_concerns(%CouncilDecision{} = decision) do
    # Combine primary concerns with all evaluation concerns
    eval_concerns = Enum.flat_map(decision.evaluations, & &1.concerns)
    Enum.uniq(decision.primary_concerns ++ eval_concerns)
  end

  defp build_explicit_chains(proposals) do
    # Map proposal_id -> proposal for quick lookup
    proposal_map = Map.new(proposals, &{&1.id, &1})

    # Find proposals with parent_proposal_id in metadata
    {children, _roots} =
      Enum.split_with(proposals, fn p ->
        Map.has_key?(p.metadata, :parent_proposal_id) or
          Map.has_key?(p.metadata, "parent_proposal_id")
      end)

    # Build chains by following parent links
    chains =
      Enum.reduce(children, [], fn child, acc ->
        parent_id =
          Map.get(child.metadata, :parent_proposal_id) ||
            Map.get(child.metadata, "parent_proposal_id")

        add_child_to_chains(acc, child, Map.get(proposal_map, parent_id))
      end)

    # Proposals not in any chain
    chained_ids = chains |> List.flatten() |> Enum.map(& &1.id) |> MapSet.new()
    unchained = Enum.reject(proposals, &MapSet.member?(chained_ids, &1.id))

    {chains, unchained}
  end

  # Parent not found, ignore this child
  defp add_child_to_chains(chains, _child, nil), do: chains

  defp add_child_to_chains(chains, child, parent) do
    {chain, remaining} = find_chain_containing(chains, parent.id)

    case chain do
      nil -> [[parent, child] | chains]
      existing -> [existing ++ [child] | remaining]
    end
  end

  defp find_chain_containing(chains, proposal_id) do
    case Enum.split_with(chains, fn chain ->
           Enum.any?(chain, &(&1.id == proposal_id))
         end) do
      {[chain], remaining} -> {chain, remaining}
      {[], _} -> {nil, chains}
      {multiple, remaining} -> {List.first(multiple), remaining ++ tl(multiple)}
    end
  end

  defp build_implicit_chains(proposals, window_ms) do
    # Group by change_type
    by_type = Enum.group_by(proposals, & &1.change_type)

    Enum.flat_map(by_type, fn {_type, type_proposals} ->
      # Sort by time and find sequences within the window
      sorted = Enum.sort_by(type_proposals, & &1.created_at, DateTime)
      find_time_clusters(sorted, window_ms)
    end)
  end

  defp find_time_clusters([], _window_ms), do: []
  defp find_time_clusters([single], _window_ms), do: [[single]]

  defp find_time_clusters([first | rest], window_ms) do
    {cluster, remaining} = collect_cluster([first], rest, window_ms)
    [cluster | find_time_clusters(remaining, window_ms)]
  end

  defp collect_cluster(cluster, [], _window_ms), do: {cluster, []}

  defp collect_cluster(cluster, [next | rest], window_ms) do
    last = List.last(cluster)
    diff_ms = DateTime.diff(next.created_at, last.created_at, :millisecond)

    if diff_ms <= window_ms do
      collect_cluster(cluster ++ [next], rest, window_ms)
    else
      {cluster, [next | rest]}
    end
  end

  defp safe_ratio(_numerator, 0), do: 0.0
  defp safe_ratio(numerator, denominator), do: Float.round(numerator / denominator, 2)
end
