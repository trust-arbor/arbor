defmodule Arbor.Memory.IdentityConsolidator.Promotion do
  @moduledoc """
  Handles KnowledgeGraph insight promotion, blocking, and categorization.

  Extracted from `Arbor.Memory.IdentityConsolidator` to reduce module size.
  Manages the lifecycle of insights from detection through promotion to identity,
  including maturation checks, blocking/unblocking, and post-consolidation analysis.
  """

  alias Arbor.Memory.{Events, KnowledgeGraph, Patterns, Signals}

  # Promotion thresholds (matching arbor_seed defaults)
  @default_min_age_days 3
  @default_min_confidence 0.75
  @default_min_access_count 3
  @default_min_relevance 0.5
  @default_fast_track_confidence 0.9

  # ETS tables
  @rate_limit_ets :arbor_identity_rate_limits
  @self_knowledge_ets :arbor_self_knowledge
  @consolidation_state_ets :arbor_consolidation_state
  @graph_ets :arbor_memory_graphs

  # ============================================================================
  # Promotion Candidates (KG-based)
  # ============================================================================

  @doc """
  Find self-insights in the KnowledgeGraph that meet all promotion criteria.

  This is a dry-run inspection -- it does not apply any changes.

  ## Options

  - `:min_age_days` - Minimum insight age in days (default: 3)
  - `:min_confidence` - Minimum confidence threshold (default: 0.75)
  - `:min_access_count` - Minimum access count (default: 3)
  - `:min_relevance` - Minimum relevance threshold (default: 0.5)
  - `:fast_track` - Allow high-confidence insights to skip maturation (default: false)
  - `:fast_track_confidence` - Confidence threshold for fast-tracking (default: 0.9)
  """
  @spec find_promotion_candidates(String.t(), keyword()) :: [map()]
  def find_promotion_candidates(agent_id, opts \\ []) do
    case get_graph(agent_id) do
      {:ok, graph} ->
        criteria_config = %{
          min_confidence: Keyword.get(opts, :min_confidence, @default_min_confidence),
          min_relevance: Keyword.get(opts, :min_relevance, @default_min_relevance),
          min_age_days: Keyword.get(opts, :min_age_days, @default_min_age_days),
          min_access_count: Keyword.get(opts, :min_access_count, @default_min_access_count),
          fast_track: Keyword.get(opts, :fast_track, false),
          fast_track_confidence: Keyword.get(opts, :fast_track_confidence, @default_fast_track_confidence),
          now: DateTime.utc_now()
        }

        criteria_fn = fn node -> meets_promotion_criteria?(node, criteria_config) end

        KnowledgeGraph.find_by_type_and_criteria(graph, :insight, criteria_fn,
          sort_by: :confidence
        )

      {:error, _} ->
        []
    end
  end

  @doc """
  Find all insight-type nodes for an agent in the KnowledgeGraph.
  """
  def find_all_insight_nodes(agent_id) do
    case get_graph(agent_id) do
      {:ok, graph} -> KnowledgeGraph.find_by_type(graph, :insight)
      _ -> []
    end
  end

  @doc """
  Check if a node meets all promotion criteria.
  """
  def meets_promotion_criteria?(node, config) do
    metadata = node.metadata || %{}

    confidence_ok = node.confidence >= config.min_confidence
    relevance_ok = node.relevance >= config.min_relevance
    evidence_ok = has_valid_evidence?(node)
    not_blocked = metadata[:promotion_blocked] != true
    not_promoted = is_nil(metadata[:promoted_at])
    maturation_ok = maturation_met?(node, config)

    confidence_ok and relevance_ok and evidence_ok and not_blocked and
      not_promoted and maturation_ok
  end

  @doc """
  Check if a node has met maturation requirements (age + access count).
  High-confidence fast-tracked insights can skip maturation.
  """
  def maturation_met?(node, config) do
    if config.fast_track and node.confidence >= config.fast_track_confidence do
      true
    else
      age_ok = node_age_days(node, config.now) >= config.min_age_days
      access_ok = (node.access_count || 0) >= config.min_access_count
      age_ok and access_ok
    end
  end

  # ============================================================================
  # Block / Unblock
  # ============================================================================

  @doc """
  Block an insight from being promoted to identity.

  This allows humans to prevent specific insights from ever being promoted
  to the core identity. Sets `promotion_blocked: true` in the KG node metadata.
  """
  @spec block_insight(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def block_insight(agent_id, insight_id, reason) do
    case get_graph(agent_id) do
      {:ok, graph} ->
        case merge_node_metadata(graph, insight_id, %{
               promotion_blocked: true,
               blocked_reason: reason,
               blocked_at: DateTime.utc_now()
             }) do
          {:ok, updated_graph} ->
            save_graph(agent_id, updated_graph)
            Signals.emit_insight_blocked(agent_id, insight_id, reason)
            :ok

          {:error, _} = error ->
            error
        end

      {:error, _} ->
        {:error, :no_graph}
    end
  end

  @doc """
  Unblock an insight, allowing it to be considered for promotion again.
  """
  @spec unblock_insight(String.t(), String.t()) :: :ok | {:error, term()}
  def unblock_insight(agent_id, insight_id) do
    case get_graph(agent_id) do
      {:ok, graph} ->
        case merge_node_metadata(graph, insight_id, %{
               promotion_blocked: false,
               blocked_reason: nil,
               blocked_at: nil
             }) do
          {:ok, updated_graph} ->
            save_graph(agent_id, updated_graph)
            :ok

          {:error, _} = error ->
            error
        end

      {:error, _} ->
        {:error, :no_graph}
    end
  end

  # ============================================================================
  # Categorization + Signals
  # ============================================================================

  @doc """
  Categorize insight nodes into promoted, deferred, and blocked groups.
  """
  def categorize_insights(all_insight_nodes, promoted_candidates) do
    promoted_ids = MapSet.new(Enum.map(promoted_candidates, & &1.id))

    remaining =
      Enum.reject(all_insight_nodes, &MapSet.member?(promoted_ids, &1.id))

    {deferred, blocked} =
      Enum.split_with(remaining, fn node ->
        not ((node.metadata || %{})[:promotion_blocked] == true)
      end)

    {promoted_ids, deferred, blocked}
  end

  @doc """
  Determine which promotion criteria a node is missing.
  """
  def missing_criteria(node, now, opts \\ []) do
    min_age = Keyword.get(opts, :min_age_days, @default_min_age_days)
    min_conf = Keyword.get(opts, :min_confidence, @default_min_confidence)
    min_access = Keyword.get(opts, :min_access_count, @default_min_access_count)
    min_rel = Keyword.get(opts, :min_relevance, @default_min_relevance)

    missing = []
    missing = if node_age_days(node, now) < min_age, do: [:min_age | missing], else: missing

    missing =
      if node.confidence < min_conf, do: [:min_confidence | missing], else: missing

    missing =
      if (node.access_count || 0) < min_access,
        do: [:min_access_count | missing],
        else: missing

    missing =
      if node.relevance < min_rel, do: [:min_relevance | missing], else: missing

    missing =
      if has_valid_evidence?(node), do: missing, else: [:evidence | missing]

    Enum.reverse(missing)
  end

  @doc """
  Emit signals for deferred insights with missing criteria details.
  """
  def emit_deferred_signals(_agent_id, []), do: :ok

  def emit_deferred_signals(agent_id, deferred_insights) do
    now = DateTime.utc_now()

    Enum.each(deferred_insights, fn node ->
      missing = missing_criteria(node, now)
      reason = "Missing: #{Enum.map_join(missing, ", ", &to_string/1)}"
      Signals.emit_insight_deferred(agent_id, node.id, reason)
    end)
  end

  @doc """
  Emit signals for blocked insights.
  """
  def emit_blocked_signals(_agent_id, []), do: :ok

  def emit_blocked_signals(agent_id, blocked_insights) do
    Enum.each(blocked_insights, fn node ->
      reason = (node.metadata || %{})[:blocked_reason] || "Blocked by human"
      Signals.emit_insight_blocked(agent_id, node.id, reason)
    end)
  end

  @doc """
  Emit identity change events and cognitive adjustment signals.
  """
  def emit_change_events(agent_id, changes) do
    Enum.each(changes, fn change ->
      Events.record_identity_changed(agent_id, change)
      Signals.emit_cognitive_adjustment(agent_id, :identity_consolidated, change)
    end)
  end

  @doc """
  Mark promoted KG insight nodes to prevent re-promotion.
  """
  def mark_insights_promoted(agent_id, promoted_candidates) do
    case get_graph(agent_id) do
      {:ok, graph} ->
        now = DateTime.utc_now()

        updated_graph =
          Enum.reduce(promoted_candidates, graph, fn node, acc_graph ->
            promote_single_node(acc_graph, agent_id, node, now)
          end)

        save_graph(agent_id, updated_graph)
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Mark a single node as promoted in the KnowledgeGraph.
  """
  def promote_single_node(graph, agent_id, node, now) do
    case merge_node_metadata(graph, node.id, %{
           promoted_at: DateTime.to_iso8601(now),
           promotion_blocked: true
         }) do
      {:ok, new_graph} ->
        Signals.emit_insight_promoted(agent_id, node.id, %{
          content: node.content,
          confidence: node.confidence
        })

        new_graph

      {:error, _} ->
        graph
    end
  end

  # ============================================================================
  # Pattern Analysis
  # ============================================================================

  @doc """
  Run post-consolidation pattern analysis and convert suggestions to insights.
  """
  def analyze_patterns_post_consolidation(agent_id, opts) do
    if Keyword.get(opts, :analyze_patterns, true) do
      agent_id |> Patterns.analyze() |> suggestions_to_insights()
    else
      []
    end
  end

  @doc """
  Convert pattern analysis suggestions to insight maps.
  """
  def suggestions_to_insights(%{suggestions: suggestions})
      when is_list(suggestions) and suggestions != [] do
    Enum.map(suggestions, &suggestion_to_insight/1)
  end

  def suggestions_to_insights(_), do: []

  defp suggestion_to_insight(text) do
    %{
      content: text,
      category: :preference,
      confidence: 0.6,
      evidence: ["pattern_analysis"],
      source: :pattern_analysis
    }
  end

  # ============================================================================
  # Graph Helpers
  # ============================================================================

  @doc false
  def get_graph(agent_id) do
    ensure_ets_exists()

    if :ets.whereis(@graph_ets) != :undefined do
      case :ets.lookup(@graph_ets, agent_id) do
        [{^agent_id, graph}] -> {:ok, graph}
        [] -> {:error, :no_graph}
      end
    else
      {:error, :no_graph}
    end
  end

  @doc false
  def save_graph(agent_id, graph) do
    ensure_ets_exists()

    if :ets.whereis(@graph_ets) != :undefined do
      :ets.insert(@graph_ets, {agent_id, graph})
    end

    :ok
  end

  @doc false
  def merge_node_metadata(graph, node_id, new_fields) do
    case KnowledgeGraph.get_node(graph, node_id) do
      {:ok, node} ->
        merged = Map.merge(node.metadata || %{}, new_fields)
        KnowledgeGraph.update_node(graph, node_id, %{metadata: merged})

      error ->
        error
    end
  end

  @doc false
  def node_age_days(node, now) do
    case node.created_at do
      nil -> 0
      %DateTime{} = created_at -> DateTime.diff(now, created_at, :second) / 86_400
      _ -> 0
    end
  end

  @doc false
  def has_valid_evidence?(node) do
    evidence = (node.metadata || %{})[:evidence]

    cond do
      is_list(evidence) and evidence != [] -> true
      is_map(evidence) and evidence != %{} -> true
      is_binary(evidence) and evidence != "" -> true
      true -> false
    end
  end

  @doc false
  def ensure_ets_exists do
    for table <- [@rate_limit_ets, @self_knowledge_ets, @consolidation_state_ets] do
      if :ets.whereis(table) == :undefined do
        try do
          :ets.new(table, [:named_table, :public, :set])
        rescue
          ArgumentError -> :ok
        end
      end
    end
  end
end
