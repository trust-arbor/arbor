defmodule Arbor.Memory.IdentityConsolidator do
  @moduledoc """
  Promotes high-confidence insights to core identity.

  IdentityConsolidator bridges the gap between detected insights (from InsightDetector)
  and the agent's permanent self-knowledge (SelfKnowledge struct). It:

  1. Gathers high-confidence insights from InsightDetector (ephemeral suggestions)
  2. Finds mature insights in KnowledgeGraph meeting promotion criteria
  3. Checks for contradictions with existing SelfKnowledge
  4. Resolves contradictions (newer evidence wins, with safeguards)
  5. Promotes consistent insights to SelfKnowledge
  6. Marks promoted KG insights to prevent re-promotion
  7. Emits signals for deferred/blocked insights with missing criteria detail
  8. Runs post-consolidation memory pattern analysis
  9. Maintains rate limits to prevent identity thrashing

  ## Promotion Criteria (KG-based insights)

  For a KG insight to be promoted, ALL of the following must be true:

  - Age >= 3 days (configurable via `:min_age_days`)
  - Confidence >= 0.75 (configurable via `:min_confidence`)
  - Access count >= 3 (configurable via `:min_access_count`)
  - Relevance >= 0.5 (configurable via `:min_relevance`)
  - Has evidence in metadata
  - Not blocked by human (`promotion_blocked` is false)
  - Not already promoted (`promoted_at` is nil)

  High-confidence insights (>= 0.9) can skip age and access requirements
  when `:fast_track` is enabled.

  ## Rate Limiting

  Identity changes are significant events that shouldn't happen too frequently.
  Default limits:
  - Maximum 3 changes per 24 hours
  - Minimum 4 hour cooldown between consolidations

  ## Human Override

  Insights can be blocked from promotion:

      :ok = IdentityConsolidator.block_insight("agent_001", "node_123", "Not representative")
      :ok = IdentityConsolidator.unblock_insight("agent_001", "node_123")

  ## Agent Type Filtering

  By default, consolidation is enabled for all agent types. This can be
  configured via application config:

      config :arbor_memory, :identity_consolidation,
        enabled_for: [:native, :hybrid],
        disabled_for: [:bridged]

  ## Usage

      if IdentityConsolidator.should_consolidate?("agent_001") do
        {:ok, sk, result} = IdentityConsolidator.consolidate("agent_001")
      end

      # Dry-run: inspect candidates without applying
      candidates = IdentityConsolidator.find_promotion_candidates("agent_001")

      # Check consolidation state
      state = IdentityConsolidator.get_consolidation_state("agent_001")
  """

  alias Arbor.Memory.{Events, InsightDetector, KnowledgeGraph, Patterns, SelfKnowledge, Signals}

  @max_changes_per_day 3
  @cooldown_hours 4
  @cooldown_ms @cooldown_hours * 60 * 60 * 1000

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
  # Main API
  # ============================================================================

  @doc """
  Consolidate insights into identity for an agent.

  This is the main entry point. It:
  1. Checks if consolidation should run (rate limits, agent type)
  2. Gathers high-confidence insights from InsightDetector
  3. Finds mature KG insights meeting promotion criteria
  4. Categorizes all insights (promoted/deferred/blocked)
  5. Checks for contradictions with existing SelfKnowledge
  6. Resolves contradictions and promotes insights
  7. Marks promoted KG insights to prevent re-promotion
  8. Emits deferred/blocked signals with missing criteria detail
  9. Runs post-consolidation pattern analysis
  10. Updates consolidation state and emits events

  ## Options

  - `:force` - Skip rate limit checks (default: false)
  - `:min_confidence` - Minimum confidence for InsightDetector insights (default: 0.7)
  - `:fast_track` - Allow high-confidence KG insights to skip maturation (default: false)
  - `:analyze_patterns` - Run memory pattern analysis post-consolidation (default: true)
  - `:min_age_days` - Min age for KG promotion (default: 3)
  - `:min_access_count` - Min access count for KG promotion (default: 3)
  - `:min_relevance` - Min relevance for KG promotion (default: 0.5)

  ## Returns

  - `{:ok, updated_sk, result}` - Updated SelfKnowledge with result metadata
  - `{:ok, :no_changes}` - No insights to consolidate
  - `{:error, :rate_limited}` - Rate limit exceeded
  - `{:error, :disabled_for_agent_type}` - Agent type not allowed

  ## Examples

      {:ok, sk, result} = IdentityConsolidator.consolidate("agent_001")
      {:ok, sk, result} = IdentityConsolidator.consolidate("agent_001", force: true)
  """
  @spec consolidate(String.t(), keyword()) ::
          {:ok, SelfKnowledge.t(), map()} | {:ok, :no_changes} | {:error, term()}
  def consolidate(agent_id, opts \\ []) do
    force = Keyword.get(opts, :force, false)
    min_confidence = Keyword.get(opts, :min_confidence, 0.7)

    with {:ok, :allowed} <- check_consolidation_allowed(agent_id, force) do
      # Source 1: InsightDetector suggestions (ephemeral)
      detector_insights = get_high_confidence_insights(agent_id, min_confidence)

      # Source 2: KG promotion candidates (matured nodes)
      kg_candidates = find_promotion_candidates(agent_id, opts)

      # Categorize all KG insight nodes
      all_kg_insights = find_all_insight_nodes(agent_id)
      {_promoted_ids, deferred, blocked} = categorize_insights(all_kg_insights, kg_candidates)

      # If no insights from either source, nothing to do
      if detector_insights == [] and kg_candidates == [] do
        {:ok, :no_changes}
      else
        sk = get_or_create_self_knowledge(agent_id)

        # Snapshot before changes
        sk = SelfKnowledge.snapshot(sk)

        # Process InsightDetector suggestions (existing per-insight integration)
        {updated_sk, detector_changes} =
          Enum.reduce(detector_insights, {sk, []}, fn insight, {acc_sk, acc_changes} ->
            case integrate_insight(acc_sk, insight) do
              {:ok, new_sk, change} -> {new_sk, [change | acc_changes]}
              {:skip, _reason} -> {acc_sk, acc_changes}
            end
          end)

        # Process KG promotion candidates (category-based synthesis)
        {updated_sk, kg_changes} = synthesize_from_kg_candidates(updated_sk, kg_candidates)

        all_changes = Enum.reverse(detector_changes) ++ Enum.reverse(kg_changes)

        if all_changes != [] do
          # Save updated SelfKnowledge
          save_self_knowledge(agent_id, updated_sk)

          # Record rate limit
          record_consolidation(agent_id)

          # Mark promoted KG insights (prevents re-promotion)
          mark_insights_promoted(agent_id, kg_candidates)

          # Emit deferred/blocked signals
          emit_deferred_signals(agent_id, deferred)
          emit_blocked_signals(agent_id, blocked)

          # Pattern analysis post-consolidation
          pattern_insights = analyze_patterns_post_consolidation(agent_id, opts)

          # Update consolidation state
          state = update_consolidation_state(agent_id)

          # Emit events for each change
          Enum.each(all_changes, fn change ->
            Events.record_identity_changed(agent_id, change)
            Signals.emit_cognitive_adjustment(agent_id, :identity_consolidated, change)
          end)

          # Emit consolidation completed signal
          result = %{
            promoted_count: length(kg_candidates),
            deferred_count: length(deferred),
            blocked_count: length(blocked),
            pattern_insights_count: length(pattern_insights),
            detector_changes_count: length(detector_changes),
            changes_made: all_changes,
            consolidation_number: state.consolidation_count
          }

          Signals.emit_consolidation_completed(agent_id, result)

          {:ok, updated_sk, result}
        else
          {:ok, :no_changes}
        end
      end
    else
      {:error, _} = error ->
        error
    end
  end

  @doc """
  Check if consolidation should run for an agent.

  Considers:
  - Agent type (native vs bridged)
  - Rate limits (max 3/day, 4hr cooldown)

  ## Options

  - `:force` - Skip all checks (default: false)
  - `:agent_type` - Override detected agent type

  ## Examples

      if IdentityConsolidator.should_consolidate?("agent_001") do
        # Run consolidation
      end
  """
  @spec should_consolidate?(String.t(), keyword()) :: boolean()
  def should_consolidate?(agent_id, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    if force do
      true
    else
      case check_consolidation_allowed(agent_id, false) do
        {:ok, :allowed} -> true
        {:error, _} -> false
      end
    end
  end

  @doc """
  Rollback identity to a previous version.

  ## Examples

      {:ok, sk} = IdentityConsolidator.rollback("agent_001")
      {:ok, sk} = IdentityConsolidator.rollback("agent_001", 3)
  """
  @spec rollback(String.t(), :previous | pos_integer()) ::
          {:ok, SelfKnowledge.t()} | {:error, term()}
  def rollback(agent_id, version \\ :previous) do
    case get_self_knowledge(agent_id) do
      nil ->
        {:error, :no_self_knowledge}

      sk ->
        case SelfKnowledge.rollback(sk, version) do
          {:error, _} = error ->
            error

          updated_sk ->
            save_self_knowledge(agent_id, updated_sk)

            Events.record_identity_changed(agent_id, %{
              field: :rollback,
              old_value: sk.version,
              new_value: updated_sk.version,
              reason: "manual_rollback"
            })

            {:ok, updated_sk}
        end
    end
  end

  @doc """
  Get identity change history for an agent.

  ## Options

  - `:limit` - Maximum entries to return
  - `:since` - Only changes after this DateTime

  ## Examples

      {:ok, history} = IdentityConsolidator.history("agent_001")
  """
  @spec history(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def history(agent_id, opts \\ []) do
    Events.get_by_type(agent_id, :identity_changed, opts)
  end

  # ============================================================================
  # SelfKnowledge Storage
  # ============================================================================

  @doc """
  Get SelfKnowledge for an agent.
  """
  @spec get_self_knowledge(String.t()) :: SelfKnowledge.t() | nil
  def get_self_knowledge(agent_id) do
    ensure_ets_exists()

    case :ets.lookup(@self_knowledge_ets, agent_id) do
      [{^agent_id, sk}] -> sk
      [] -> nil
    end
  end

  @doc """
  Save SelfKnowledge for an agent.
  """
  @spec save_self_knowledge(String.t(), SelfKnowledge.t()) :: :ok
  def save_self_knowledge(agent_id, %SelfKnowledge{} = sk) do
    ensure_ets_exists()
    :ets.insert(@self_knowledge_ets, {agent_id, sk})
    :ok
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp check_consolidation_allowed(agent_id, force) do
    cond do
      force ->
        {:ok, :allowed}

      not agent_type_allowed?(agent_id) ->
        {:error, :disabled_for_agent_type}

      rate_limited?(agent_id) ->
        {:error, :rate_limited}

      true ->
        {:ok, :allowed}
    end
  end

  defp agent_type_allowed?(agent_id) do
    config = Application.get_env(:arbor_memory, :identity_consolidation, [])
    enabled_for = Keyword.get(config, :enabled_for)
    disabled_for = Keyword.get(config, :disabled_for, [])

    # Get agent type (default to :native if not specified)
    agent_type = get_agent_type(agent_id)

    cond do
      # Explicitly disabled
      agent_type in disabled_for ->
        false

      # Explicitly enabled list exists
      is_list(enabled_for) and enabled_for != [] ->
        agent_type in enabled_for

      # Default: allow all
      true ->
        true
    end
  end

  defp get_agent_type(_agent_id) do
    # In a full implementation, this would query the agent registry
    # For now, default to :native
    :native
  end

  defp rate_limited?(agent_id) do
    ensure_ets_exists()

    case :ets.lookup(@rate_limit_ets, agent_id) do
      [{^agent_id, timestamps}] ->
        now = System.monotonic_time(:millisecond)
        day_ago = now - 24 * 60 * 60 * 1000

        # Filter to last 24 hours
        recent = Enum.filter(timestamps, &(&1 > day_ago))

        # Check limits
        cond do
          # Max changes per day
          length(recent) >= @max_changes_per_day ->
            true

          # Cooldown between consolidations
          recent != [] and now - Enum.max(recent) < @cooldown_ms ->
            true

          true ->
            false
        end

      [] ->
        false
    end
  end

  defp record_consolidation(agent_id) do
    ensure_ets_exists()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@rate_limit_ets, agent_id) do
      [{^agent_id, timestamps}] ->
        # Keep last 10 timestamps
        updated = [now | timestamps] |> Enum.take(10)
        :ets.insert(@rate_limit_ets, {agent_id, updated})

      [] ->
        :ets.insert(@rate_limit_ets, {agent_id, [now]})
    end

    :ok
  end

  defp get_high_confidence_insights(agent_id, min_confidence) do
    case InsightDetector.detect(agent_id, include_low_confidence: false) do
      {:error, _} ->
        []

      insights when is_list(insights) ->
        Enum.filter(insights, fn i ->
          i.confidence >= min_confidence and i.category in [:personality, :capability, :value]
        end)
    end
  end

  defp get_or_create_self_knowledge(agent_id) do
    case get_self_knowledge(agent_id) do
      nil -> SelfKnowledge.new(agent_id)
      sk -> sk
    end
  end

  defp integrate_insight(sk, insight) do
    case insight.category do
      :personality ->
        integrate_personality_insight(sk, insight)

      :capability ->
        integrate_capability_insight(sk, insight)

      :value ->
        integrate_value_insight(sk, insight)

      _ ->
        {:skip, :unknown_category}
    end
  end

  defp integrate_personality_insight(sk, insight) do
    # Extract trait from insight content
    trait = extract_trait_from_insight(insight)

    if trait do
      # Check for contradiction
      existing = Enum.find(sk.personality_traits, &(&1.trait == trait))

      if existing && contradicts?(existing.strength, insight.confidence) do
        # Newer evidence wins, but record the change
        updated_sk = SelfKnowledge.add_trait(sk, trait, insight.confidence, hd(insight.evidence))

        change = %{
          field: :personality_traits,
          old_value: {trait, existing.strength},
          new_value: {trait, insight.confidence},
          reason: "new_evidence"
        }

        {:ok, updated_sk, change}
      else
        # No contradiction, just add/update
        updated_sk = SelfKnowledge.add_trait(sk, trait, insight.confidence, hd(insight.evidence))

        change = %{
          field: :personality_traits,
          old_value: existing && {trait, existing.strength},
          new_value: {trait, insight.confidence},
          reason: "insight_detected"
        }

        {:ok, updated_sk, change}
      end
    else
      {:skip, :could_not_extract_trait}
    end
  end

  defp integrate_capability_insight(sk, insight) do
    # Extract capability from insight content
    capability = extract_capability_from_insight(insight)

    if capability do
      existing = Enum.find(sk.capabilities, &(&1.name == capability))
      evidence = if insight.evidence != [], do: hd(insight.evidence), else: nil

      updated_sk =
        SelfKnowledge.add_capability(
          sk,
          capability,
          insight.confidence,
          evidence
        )

      change = %{
        field: :capabilities,
        old_value: existing && {capability, existing.proficiency},
        new_value: {capability, insight.confidence},
        reason: "insight_detected"
      }

      {:ok, updated_sk, change}
    else
      {:skip, :could_not_extract_capability}
    end
  end

  defp integrate_value_insight(sk, insight) do
    # Extract value from insight content
    value = extract_value_from_insight(insight)

    if value do
      existing = Enum.find(sk.values, &(&1.value == value))
      evidence = if insight.evidence != [], do: hd(insight.evidence), else: nil

      updated_sk =
        SelfKnowledge.add_value(
          sk,
          value,
          insight.confidence,
          evidence
        )

      change = %{
        field: :values,
        old_value: existing && {value, existing.importance},
        new_value: {value, insight.confidence},
        reason: "insight_detected"
      }

      {:ok, updated_sk, change}
    else
      {:skip, :could_not_extract_value}
    end
  end

  # Check if two values contradict (differ significantly)
  defp contradicts?(old_value, new_value) do
    abs(old_value - new_value) > 0.3
  end

  # Extract a trait atom from insight content
  # This is a simple heuristic; a more sophisticated implementation
  # would use NLP or the insight's metadata
  @known_traits ~w(curious methodical thorough reflective analytical detail_oriented)a

  defp extract_trait_from_insight(insight) do
    content_lower = String.downcase(insight.content)

    Enum.find(@known_traits, fn trait ->
      trait_str = Atom.to_string(trait)
      String.contains?(content_lower, trait_str) or
        String.contains?(content_lower, String.replace(trait_str, "_", "-")) or
        String.contains?(content_lower, String.replace(trait_str, "_", " "))
    end)
  end

  # Extract a capability name from insight content
  @known_capabilities ~w(associative_thinking evidence_based_reasoning knowledge_retention)

  defp extract_capability_from_insight(insight) do
    content_lower = String.downcase(insight.content)

    found =
      Enum.find(@known_capabilities, fn cap ->
        String.contains?(content_lower, cap) or
          String.contains?(content_lower, String.replace(cap, "_", "-")) or
          String.contains?(content_lower, String.replace(cap, "_", " "))
      end)

    # If not found in known list, try to extract from "highly interconnected" pattern
    cond do
      found ->
        found

      String.contains?(content_lower, "interconnected") ->
        "associative_thinking"

      String.contains?(content_lower, "evidence") or
          String.contains?(content_lower, "supporting") ->
        "evidence_based_reasoning"

      String.contains?(content_lower, "knowledge base") ->
        "knowledge_retention"

      true ->
        nil
    end
  end

  # Extract a value atom from insight content
  @known_values ~w(growth learning capability_development self_reflection)a

  defp extract_value_from_insight(insight) do
    content_lower = String.downcase(insight.content)

    found =
      Enum.find(@known_values, fn val ->
        val_str = Atom.to_string(val)

        String.contains?(content_lower, val_str) or
          String.contains?(content_lower, String.replace(val_str, "_", "-")) or
          String.contains?(content_lower, String.replace(val_str, "_", " "))
      end)

    found || match_value_pattern(content_lower)
  end

  defp match_value_pattern(content) when is_binary(content) do
    cond do
      String.contains?(content, "growth mindset") or
          String.contains?(content, "capability development") ->
        :growth

      String.contains?(content, "self-reflection") or
          String.contains?(content, "metacognition") ->
        :self_reflection

      String.contains?(content, "learning") or
          String.contains?(content, "skills") ->
        :learning

      true ->
        nil
    end
  end

  defp ensure_ets_exists do
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

  # ============================================================================
  # KG Helpers
  # ============================================================================

  defp get_graph(agent_id) do
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

  defp save_graph(agent_id, graph) do
    ensure_ets_exists()

    if :ets.whereis(@graph_ets) != :undefined do
      :ets.insert(@graph_ets, {agent_id, graph})
    end

    :ok
  end

  defp merge_node_metadata(graph, node_id, new_fields) do
    case KnowledgeGraph.get_node(graph, node_id) do
      {:ok, node} ->
        merged = Map.merge(node.metadata || %{}, new_fields)
        KnowledgeGraph.update_node(graph, node_id, %{metadata: merged})

      error ->
        error
    end
  end

  defp node_age_days(node, now) do
    case node.created_at do
      nil -> 0
      %DateTime{} = created_at -> DateTime.diff(now, created_at, :second) / 86_400
      _ -> 0
    end
  end

  defp has_valid_evidence?(node) do
    evidence = (node.metadata || %{})[:evidence]

    cond do
      is_list(evidence) and evidence != [] -> true
      is_map(evidence) and evidence != %{} -> true
      is_binary(evidence) and evidence != "" -> true
      true -> false
    end
  end

  # ============================================================================
  # Consolidation State
  # ============================================================================

  @doc """
  Get consolidation state for an agent.

  Returns a map with `:consolidation_count` and `:last_consolidation_at`.
  """
  @spec get_consolidation_state(String.t()) :: map()
  def get_consolidation_state(agent_id) do
    ensure_ets_exists()

    case :ets.lookup(@consolidation_state_ets, agent_id) do
      [{^agent_id, state}] -> state
      [] -> %{consolidation_count: 0, last_consolidation_at: nil}
    end
  end

  defp update_consolidation_state(agent_id) do
    ensure_ets_exists()
    current = get_consolidation_state(agent_id)

    new_state = %{
      consolidation_count: current.consolidation_count + 1,
      last_consolidation_at: DateTime.utc_now()
    }

    :ets.insert(@consolidation_state_ets, {agent_id, new_state})
    new_state
  end

  # ============================================================================
  # Promotion Candidates (KG-based)
  # ============================================================================

  @doc """
  Find self-insights in the KnowledgeGraph that meet all promotion criteria.

  This is a dry-run inspection — it does not apply any changes.

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
        min_age_days = Keyword.get(opts, :min_age_days, @default_min_age_days)
        min_confidence = Keyword.get(opts, :min_confidence, @default_min_confidence)
        min_access_count = Keyword.get(opts, :min_access_count, @default_min_access_count)
        min_relevance = Keyword.get(opts, :min_relevance, @default_min_relevance)
        fast_track = Keyword.get(opts, :fast_track, false)
        fast_track_confidence = Keyword.get(opts, :fast_track_confidence, @default_fast_track_confidence)

        now = DateTime.utc_now()

        criteria_fn = fn node ->
          confidence_ok = node.confidence >= min_confidence
          relevance_ok = node.relevance >= min_relevance
          evidence_ok = has_valid_evidence?(node)
          not_blocked = not ((node.metadata || %{})[:promotion_blocked] == true)
          not_promoted = is_nil((node.metadata || %{})[:promoted_at])

          age_ok = node_age_days(node, now) >= min_age_days
          access_ok = (node.access_count || 0) >= min_access_count

          maturation_ok =
            if fast_track and node.confidence >= fast_track_confidence do
              true
            else
              age_ok and access_ok
            end

          confidence_ok and relevance_ok and evidence_ok and not_blocked and
            not_promoted and maturation_ok
        end

        KnowledgeGraph.find_by_type_and_criteria(graph, :insight, criteria_fn,
          sort_by: :confidence
        )

      {:error, _} ->
        []
    end
  end

  defp find_all_insight_nodes(agent_id) do
    case get_graph(agent_id) do
      {:ok, graph} -> KnowledgeGraph.find_by_type(graph, :insight)
      _ -> []
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

  defp categorize_insights(all_insight_nodes, promoted_candidates) do
    promoted_ids = MapSet.new(Enum.map(promoted_candidates, & &1.id))

    remaining =
      Enum.reject(all_insight_nodes, &MapSet.member?(promoted_ids, &1.id))

    {deferred, blocked} =
      Enum.split_with(remaining, fn node ->
        not ((node.metadata || %{})[:promotion_blocked] == true)
      end)

    {promoted_ids, deferred, blocked}
  end

  defp missing_criteria(node, now, opts \\ []) do
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
      if not has_valid_evidence?(node), do: [:evidence | missing], else: missing

    Enum.reverse(missing)
  end

  defp emit_deferred_signals(_agent_id, []), do: :ok

  defp emit_deferred_signals(agent_id, deferred_insights) do
    now = DateTime.utc_now()

    Enum.each(deferred_insights, fn node ->
      missing = missing_criteria(node, now)
      reason = "Missing: #{Enum.map_join(missing, ", ", &to_string/1)}"
      Signals.emit_insight_deferred(agent_id, node.id, reason)
    end)
  end

  defp emit_blocked_signals(_agent_id, []), do: :ok

  defp emit_blocked_signals(agent_id, blocked_insights) do
    Enum.each(blocked_insights, fn node ->
      reason = (node.metadata || %{})[:blocked_reason] || "Blocked by human"
      Signals.emit_insight_blocked(agent_id, node.id, reason)
    end)
  end

  defp mark_insights_promoted(agent_id, promoted_candidates) do
    case get_graph(agent_id) do
      {:ok, graph} ->
        now = DateTime.utc_now()

        updated_graph =
          Enum.reduce(promoted_candidates, graph, fn node, acc_graph ->
            case merge_node_metadata(acc_graph, node.id, %{
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
                acc_graph
            end
          end)

        save_graph(agent_id, updated_graph)
        :ok

      _ ->
        :ok
    end
  end

  # ============================================================================
  # Pattern Analysis
  # ============================================================================

  defp analyze_patterns_post_consolidation(agent_id, opts) do
    if Keyword.get(opts, :analyze_patterns, true) do
      case Patterns.analyze(agent_id) do
        %{suggestions: suggestions} when is_list(suggestions) and suggestions != [] ->
          Enum.map(suggestions, fn text ->
            %{
              content: text,
              category: :preference,
              confidence: 0.6,
              evidence: ["pattern_analysis"],
              source: :pattern_analysis
            }
          end)

        _ ->
          []
      end
    else
      []
    end
  end

  defp get_insight_category(node) do
    meta = node.metadata || %{}
    meta[:category] || meta["category"] || :personality
  end

  defp synthesize_from_kg_candidates(sk, candidates) do
    by_category = Enum.group_by(candidates, &get_insight_category/1)

    Enum.reduce(by_category, {sk, []}, fn {category, nodes}, {acc_sk, acc_changes} ->
      Enum.reduce(nodes, {acc_sk, acc_changes}, fn node, {sk_inner, changes_inner} ->
        case apply_kg_insight(sk_inner, node, category) do
          {:ok, new_sk, change} -> {new_sk, [change | changes_inner]}
          {:skip, _} -> {sk_inner, changes_inner}
        end
      end)
    end)
  end

  defp apply_kg_insight(sk, node, category) do
    content = node.content || ""
    evidence = ((node.metadata || %{})[:evidence] || []) |> List.wrap() |> List.first()

    case category do
      cat when cat in [:personality, "personality"] ->
        trait = extract_trait_from_content(content)

        if trait do
          updated_sk = SelfKnowledge.add_trait(sk, trait, node.confidence, evidence)

          {:ok, updated_sk,
           %{
             field: :personality_traits,
             old_value: nil,
             new_value: {trait, node.confidence},
             reason: "kg_promotion",
             source_node_id: node.id
           }}
        else
          {:skip, :could_not_extract_trait}
        end

      cat when cat in [:capability, "capability"] ->
        cap = extract_capability_from_content(content)

        if cap do
          updated_sk = SelfKnowledge.add_capability(sk, cap, node.confidence, evidence)

          {:ok, updated_sk,
           %{
             field: :capabilities,
             old_value: nil,
             new_value: {cap, node.confidence},
             reason: "kg_promotion",
             source_node_id: node.id
           }}
        else
          {:skip, :could_not_extract_capability}
        end

      cat when cat in [:value, "value"] ->
        val = extract_value_from_content(content)

        if val do
          updated_sk = SelfKnowledge.add_value(sk, val, node.confidence, evidence)

          {:ok, updated_sk,
           %{
             field: :values,
             old_value: nil,
             new_value: {val, node.confidence},
             reason: "kg_promotion",
             source_node_id: node.id
           }}
        else
          {:skip, :could_not_extract_value}
        end

      _ ->
        {:skip, :unknown_category}
    end
  end

  defp extract_trait_from_content(content) do
    content_lower = String.downcase(content)

    Enum.find(@known_traits, fn trait ->
      trait_str = Atom.to_string(trait)

      String.contains?(content_lower, trait_str) or
        String.contains?(content_lower, String.replace(trait_str, "_", "-")) or
        String.contains?(content_lower, String.replace(trait_str, "_", " "))
    end)
  end

  defp extract_capability_from_content(content) do
    content_lower = String.downcase(content)

    found =
      Enum.find(@known_capabilities, fn cap ->
        String.contains?(content_lower, cap) or
          String.contains?(content_lower, String.replace(cap, "_", "-")) or
          String.contains?(content_lower, String.replace(cap, "_", " "))
      end)

    cond do
      found -> found
      String.contains?(content_lower, "interconnected") -> "associative_thinking"
      String.contains?(content_lower, "evidence") -> "evidence_based_reasoning"
      String.contains?(content_lower, "knowledge base") -> "knowledge_retention"
      true -> nil
    end
  end

  defp extract_value_from_content(content) do
    content_lower = String.downcase(content)

    found =
      Enum.find(@known_values, fn val ->
        val_str = Atom.to_string(val)

        String.contains?(content_lower, val_str) or
          String.contains?(content_lower, String.replace(val_str, "_", "-")) or
          String.contains?(content_lower, String.replace(val_str, "_", " "))
      end)

    found || match_value_pattern(content_lower)
  end
end
