defmodule Arbor.Memory.IdentityOps do
  @moduledoc """
  Sub-facade for identity, self-knowledge, preferences, and reflection operations.

  Handles self-knowledge CRUD, identity consolidation, cognitive preferences,
  reflection processing, and insight detection.

  This module is not intended to be called directly by external consumers.
  Use `Arbor.Memory` as the public API.
  """

  alias Arbor.Memory.{
    IdentityConsolidator,
    InsightDetector,
    Preferences,
    PreferencesStore,
    ReflectionProcessor,
    SelfKnowledge
  }

  # ============================================================================
  # Self-Knowledge (Phase 5)
  # ============================================================================

  @doc """
  Get the agent's self-knowledge.

  Returns the SelfKnowledge struct containing capabilities, traits,
  values, and preferences.

  ## Examples

      sk = Arbor.Memory.get_self_knowledge("agent_001")
  """
  @spec get_self_knowledge(String.t()) :: SelfKnowledge.t() | nil
  defdelegate get_self_knowledge(agent_id), to: IdentityConsolidator

  @doc """
  Serialize a SelfKnowledge struct to a JSON-safe map.
  """
  @spec serialize_self_knowledge(SelfKnowledge.t()) :: map()
  defdelegate serialize_self_knowledge(sk), to: SelfKnowledge, as: :serialize

  @doc """
  Get a human-readable summary of self-knowledge for prompt injection.
  """
  @spec summarize_self_knowledge(SelfKnowledge.t()) :: String.t()
  defdelegate summarize_self_knowledge(sk), to: SelfKnowledge, as: :summarize

  @doc """
  Add a self-insight for an agent.

  Maps category to the appropriate SelfKnowledge function:
  - `:capability` / `:skill` -> `SelfKnowledge.add_capability/4`
  - `:personality` / `:trait` -> `SelfKnowledge.add_trait/4`
  - `:value` -> `SelfKnowledge.add_value/4`
  - Other categories -> stored as a knowledge node with type `:insight`

  ## Options

  - `:confidence` - Confidence score (default: 0.5)
  - `:evidence` - Evidence for the insight

  ## Examples

      {:ok, sk} = Arbor.Memory.add_insight("agent_001", "Good at pattern matching", :capability)
  """
  @spec add_insight(String.t(), String.t(), atom(), keyword()) ::
          {:ok, SelfKnowledge.t()} | {:ok, String.t()} | {:error, term()}
  def add_insight(agent_id, content, category, opts \\ []) do
    confidence = Keyword.get(opts, :confidence, 0.5)
    evidence = Keyword.get(opts, :evidence)

    sk = get_self_knowledge(agent_id) || SelfKnowledge.new(agent_id)

    case category do
      cat when cat in [:capability, :skill] ->
        updated = SelfKnowledge.add_capability(sk, content, confidence, evidence)
        IdentityConsolidator.save_self_knowledge(agent_id, updated)
        {:ok, updated}

      cat when cat in [:personality, :trait] ->
        trait_atom = safe_insight_atom(content)
        updated = SelfKnowledge.add_trait(sk, trait_atom, confidence, evidence)
        IdentityConsolidator.save_self_knowledge(agent_id, updated)
        {:ok, updated}

      :value ->
        value_atom = safe_insight_atom(content)
        updated = SelfKnowledge.add_value(sk, value_atom, confidence, evidence)
        IdentityConsolidator.save_self_knowledge(agent_id, updated)
        {:ok, updated}

      _other ->
        # Fall back to storing as a knowledge node
        Arbor.Memory.KnowledgeOps.add_knowledge(agent_id, %{
          type: :insight,
          content: content,
          relevance: confidence,
          metadata: %{category: category, evidence: evidence}
        })
    end
  end

  @doc """
  Query a specific aspect of self-knowledge.

  ## Aspects

  - `:memory_system` - Understanding of memory architecture
  - `:identity` - Core identity (traits + values)
  - `:tools` - Tool capabilities
  - `:cognition` - Cognitive patterns and preferences
  - `:capabilities` - Skills and proficiency
  - `:all` - Everything

  ## Examples

      identity = Arbor.Memory.query_self("agent_001", :identity)
  """
  @spec query_self(String.t(), atom()) :: map()
  def query_self(agent_id, aspect) do
    case get_self_knowledge(agent_id) do
      nil -> %{}
      sk -> SelfKnowledge.query(sk, aspect)
    end
  end

  # ============================================================================
  # Identity Consolidation (Phase 5)
  # ============================================================================

  @doc """
  Apply an accepted identity change from a proposal.

  Called after the LLM accepts an identity-type proposal.
  """
  @spec apply_accepted_change(String.t(), map()) :: :ok | {:error, term()}
  defdelegate apply_accepted_change(agent_id, metadata), to: IdentityConsolidator

  @doc """
  Run identity consolidation for an agent.

  Promotes high-confidence insights from InsightDetector to
  permanent SelfKnowledge. Rate-limited to prevent identity thrashing.

  ## Options

  - `:force` - Skip rate limit checks (default: false)
  - `:min_confidence` - Minimum confidence for insights (default: 0.7)

  ## Examples

      {:ok, updated_sk} = Arbor.Memory.consolidate_identity("agent_001")
  """
  @spec consolidate_identity(String.t(), keyword()) ::
          {:ok, SelfKnowledge.t()} | {:ok, :no_changes} | {:error, term()}
  defdelegate consolidate_identity(agent_id, opts \\ []),
    to: IdentityConsolidator,
    as: :consolidate

  @doc """
  Rollback identity to a previous version.

  ## Examples

      {:ok, sk} = Arbor.Memory.rollback_identity("agent_001")
      {:ok, sk} = Arbor.Memory.rollback_identity("agent_001", 3)
  """
  @spec rollback_identity(String.t(), :previous | pos_integer()) ::
          {:ok, SelfKnowledge.t()} | {:error, term()}
  defdelegate rollback_identity(agent_id, version \\ :previous),
    to: IdentityConsolidator,
    as: :rollback

  @doc """
  Get identity change history for an agent.

  ## Examples

      {:ok, history} = Arbor.Memory.identity_history("agent_001")
  """
  @spec identity_history(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate identity_history(agent_id, opts \\ []), to: IdentityConsolidator, as: :history

  # ============================================================================
  # Preferences (Phase 5)
  # ============================================================================

  @doc "Get preferences for an agent."
  defdelegate get_preferences(agent_id), to: PreferencesStore

  @doc "Adjust a cognitive preference for an agent."
  defdelegate adjust_preference(agent_id, param, value, opts \\ []), to: PreferencesStore

  @doc "Pin a memory to protect it from decay."
  defdelegate pin_memory(agent_id, memory_id, opts \\ []), to: PreferencesStore

  @doc "Unpin a memory, allowing it to decay normally."
  defdelegate unpin_memory(agent_id, memory_id), to: PreferencesStore

  @doc "Serialize a Preferences struct to a JSON-safe map."
  defdelegate serialize_preferences(prefs), to: Preferences, as: :serialize

  @doc "Deserialize a map back into a Preferences struct."
  defdelegate deserialize_preferences(data), to: Preferences, as: :deserialize

  @doc "Get a summary of current preferences and usage."
  defdelegate inspect_preferences(agent_id), to: PreferencesStore

  @doc "Get a trust-aware introspection of current preferences."
  defdelegate introspect_preferences(agent_id, trust_tier), to: PreferencesStore

  @doc "Set a context preference for prompt building."
  defdelegate set_context_preference(agent_id, key, value), to: PreferencesStore

  @doc "Get a context preference value."
  defdelegate get_context_preference(agent_id, key, default \\ nil), to: PreferencesStore

  @doc "Save preferences for an agent (public wrapper for Seed restore)."
  defdelegate save_preferences_for_agent(agent_id, prefs), to: PreferencesStore

  # ============================================================================
  # Reflection (Phase 5)
  # ============================================================================

  @doc """
  Run a periodic reflection cycle for an agent.

  Gathers recent activity, generates a reflection prompt, and
  creates proposals from any insights found.
  """
  @spec periodic_reflection(String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate periodic_reflection(agent_id), to: ReflectionProcessor

  @doc """
  Perform a structured reflection with a specific prompt.

  Uses the configured LLM module (or mock in dev/test) to generate
  insights from the agent's context.

  ## Options

  - `:include_self_knowledge` - Include SelfKnowledge in context (default: true)
  - `:include_recent_activity` - Include recent activity summary (default: true)

  ## Examples

      {:ok, reflection} = Arbor.Memory.reflect("agent_001", "What patterns do I see?")
  """
  @spec reflect(String.t(), String.t(), keyword()) ::
          {:ok, ReflectionProcessor.reflection()} | {:error, term()}
  defdelegate reflect(agent_id, prompt, opts \\ []), to: ReflectionProcessor

  @doc """
  Perform a deep reflection with full goal evaluation, knowledge graph
  integration, and insight detection.

  ## Options

  - `:provider` - LLM provider override
  - `:model` - LLM model override

  ## Examples

      {:ok, result} = Arbor.Memory.deep_reflect("agent_001")
  """
  @spec deep_reflect(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate deep_reflect(agent_id, opts \\ []), to: ReflectionProcessor

  @doc """
  Get reflection history for an agent.

  ## Options

  - `:limit` - Maximum reflections to return (default: 10)
  - `:since` - Only reflections after this DateTime

  ## Examples

      {:ok, reflections} = Arbor.Memory.reflection_history("agent_001")
  """
  @spec reflection_history(String.t(), keyword()) :: {:ok, [ReflectionProcessor.reflection()]}
  defdelegate reflection_history(agent_id, opts \\ []), to: ReflectionProcessor, as: :history

  # ============================================================================
  # Insight Detection (Phase 4)
  # ============================================================================

  @doc """
  Detect insights from knowledge graph patterns.

  Analyzes the knowledge graph to find patterns that might indicate
  personality traits, capabilities, values, or preferences.

  ## Options

  - `:include_low_confidence` - Include suggestions below 0.5 confidence
  - `:max_suggestions` - Maximum suggestions to return (default: 5)

  ## Examples

      suggestions = Arbor.Memory.detect_insights("agent_001")
  """
  @spec detect_insights(String.t(), keyword()) ::
          [InsightDetector.insight_suggestion()] | {:error, term()}
  defdelegate detect_insights(agent_id, opts \\ []), to: InsightDetector, as: :detect

  @doc """
  Detect insights and queue them as proposals.

  ## Examples

      {:ok, proposals} = Arbor.Memory.detect_and_queue_insights("agent_001")
  """
  @spec detect_and_queue_insights(String.t(), keyword()) ::
          {:ok, [Arbor.Memory.Proposal.t()]} | {:error, term()}
  defdelegate detect_and_queue_insights(agent_id, opts \\ []),
    to: InsightDetector,
    as: :detect_and_queue

  @doc """
  Detect behavioral insights from working memory thoughts.

  Analyzes recent thoughts for patterns like curiosity, methodical,
  caution, and learning behaviors.
  """
  @spec detect_working_memory_insights(String.t(), keyword()) :: [map()]
  defdelegate detect_working_memory_insights(agent_id, opts \\ []),
    to: InsightDetector,
    as: :detect_from_working_memory

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Convert a string to an atom safely for insight categories.
  defp safe_insight_atom(name) when is_atom(name), do: name

  defp safe_insight_atom(name) when is_binary(name) do
    normalized =
      name
      |> String.downcase()
      |> String.replace(~r/\s+/, "_")

    case Arbor.Common.SafeAtom.to_existing(normalized) do
      {:ok, atom} -> atom
      {:error, _} -> normalized
    end
  end
end
