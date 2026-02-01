defmodule Arbor.Memory.IdentityConsolidator do
  @moduledoc """
  Promotes high-confidence insights to core identity.

  IdentityConsolidator bridges the gap between detected insights (from InsightDetector)
  and the agent's permanent self-knowledge (SelfKnowledge struct). It:

  1. Gathers high-confidence insights from InsightDetector
  2. Checks for contradictions with existing SelfKnowledge
  3. Resolves contradictions (newer evidence wins, with safeguards)
  4. Promotes consistent insights to SelfKnowledge
  5. Maintains rate limits to prevent identity thrashing

  ## Rate Limiting

  Identity changes are significant events that shouldn't happen too frequently.
  Default limits:
  - Maximum 3 changes per 24 hours
  - Minimum 4 hour cooldown between consolidations

  ## Agent Type Filtering

  By default, consolidation is enabled for all agent types. This can be
  configured via application config:

      config :arbor_memory, :identity_consolidation,
        enabled_for: [:native, :hybrid],
        disabled_for: [:bridged]

  ## Usage

      if IdentityConsolidator.should_consolidate?("agent_001") do
        {:ok, updated_sk} = IdentityConsolidator.consolidate("agent_001")
      end
  """

  alias Arbor.Memory.{Events, InsightDetector, SelfKnowledge, Signals}

  @max_changes_per_day 3
  @cooldown_hours 4
  @cooldown_ms @cooldown_hours * 60 * 60 * 1000

  # ETS table for rate limiting
  @rate_limit_ets :arbor_identity_rate_limits

  # ETS table for SelfKnowledge storage
  @self_knowledge_ets :arbor_self_knowledge

  # ============================================================================
  # Main API
  # ============================================================================

  @doc """
  Consolidate insights into identity for an agent.

  This is the main entry point. It:
  1. Checks if consolidation should run (rate limits, agent type)
  2. Gathers high-confidence insights from InsightDetector
  3. Checks for contradictions with existing SelfKnowledge
  4. Resolves contradictions and promotes insights
  5. Snapshots version before changes
  6. Emits identity_changed event

  ## Options

  - `:force` - Skip rate limit checks (default: false)
  - `:min_confidence` - Minimum confidence for insights (default: 0.7)

  ## Returns

  - `{:ok, updated_sk}` - Updated SelfKnowledge
  - `{:ok, :no_changes}` - No insights to consolidate
  - `{:error, :rate_limited}` - Rate limit exceeded
  - `{:error, :disabled_for_agent_type}` - Agent type not allowed

  ## Examples

      {:ok, sk} = IdentityConsolidator.consolidate("agent_001")
      {:ok, sk} = IdentityConsolidator.consolidate("agent_001", force: true)
  """
  @spec consolidate(String.t(), keyword()) ::
          {:ok, SelfKnowledge.t()} | {:ok, :no_changes} | {:error, term()}
  def consolidate(agent_id, opts \\ []) do
    force = Keyword.get(opts, :force, false)
    min_confidence = Keyword.get(opts, :min_confidence, 0.7)

    with {:ok, :allowed} <- check_consolidation_allowed(agent_id, force),
         insights <- get_high_confidence_insights(agent_id, min_confidence),
         true <- length(insights) > 0 do
      sk = get_or_create_self_knowledge(agent_id)

      # Snapshot before changes
      sk = SelfKnowledge.snapshot(sk)

      # Process each insight
      {updated_sk, changes} =
        Enum.reduce(insights, {sk, []}, fn insight, {acc_sk, acc_changes} ->
          case integrate_insight(acc_sk, insight) do
            {:ok, new_sk, change} ->
              {new_sk, [change | acc_changes]}

            {:skip, _reason} ->
              {acc_sk, acc_changes}
          end
        end)

      if length(changes) > 0 do
        # Save updated SelfKnowledge
        save_self_knowledge(agent_id, updated_sk)

        # Record rate limit
        record_consolidation(agent_id)

        # Emit events
        Enum.each(changes, fn change ->
          Events.record_identity_changed(agent_id, change)
          Signals.emit_cognitive_adjustment(agent_id, :identity_consolidated, change)
        end)

        {:ok, updated_sk}
      else
        {:ok, :no_changes}
      end
    else
      false ->
        {:ok, :no_changes}

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
          length(recent) > 0 and now - Enum.max(recent) < @cooldown_ms ->
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
        insights
        |> Enum.filter(&(&1.confidence >= min_confidence))
        |> Enum.filter(&(&1.category in [:personality, :capability, :value]))
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

    # Try pattern matching for common value indicators
    cond do
      found ->
        found

      String.contains?(content_lower, "growth mindset") or
          String.contains?(content_lower, "capability development") ->
        :growth

      String.contains?(content_lower, "self-reflection") or
          String.contains?(content_lower, "metacognition") ->
        :self_reflection

      String.contains?(content_lower, "learning") or
          String.contains?(content_lower, "skills") ->
        :learning

      true ->
        nil
    end
  end

  defp ensure_ets_exists do
    if :ets.whereis(@rate_limit_ets) == :undefined do
      try do
        :ets.new(@rate_limit_ets, [:named_table, :public, :set])
      rescue
        ArgumentError -> :ok
      end
    end

    if :ets.whereis(@self_knowledge_ets) == :undefined do
      try do
        :ets.new(@self_knowledge_ets, [:named_table, :public, :set])
      rescue
        ArgumentError -> :ok
      end
    end
  end
end
