defmodule Arbor.Memory.Proposal do
  @moduledoc """
  Unified proposal queue for the "subconscious proposes, agent decides" pattern.

  Proposals are suggestions from background processes (fact extraction, pattern
  detection, insight generation) that await agent review before integration
  into the knowledge graph.

  ## Proposal Types

  - `:fact` - Auto-extracted facts from conversation/content
  - `:insight` - Detected behavior patterns and self-insights
  - `:learning` - Tool usage patterns and workflow learnings
  - `:pattern` - Recurring sequences detected in action history
  - `:preconscious` - Anticipatory memories surfaced from current context
  - `:goal` - New goal proposed by heartbeat
  - `:goal_update` - Modification to existing goal
  - `:thought` - Thinking observation from heartbeat
  - `:concern` - Concern raised during heartbeat
  - `:curiosity` - Curiosity expression from heartbeat
  - `:identity` - Identity insight proposed by heartbeat
  - `:intent` - Decomposed intent from heartbeat
  - `:cognitive_mode` - Cognitive mode change proposed by heartbeat

  ## Lifecycle

  1. Background process creates a proposal via `create/3`
  2. Proposal sits in pending state until agent reviews
  3. Agent calls `accept/2`, `reject/2`, or `defer/2`
  4. Accepted proposals are promoted to KnowledgeGraph
  5. Rejected proposals are removed (with calibration feedback)
  6. Deferred proposals stay in queue for later review

  ## Deduplication

  When creating a proposal, the system checks for existing pending/deferred
  proposals of the same type with similar content. If a match is found
  (exact case-insensitive match, or Jaccard word-set similarity >= 0.6),
  the existing proposal's confidence is boosted instead of creating a duplicate.
  Additionally, proposals are checked against existing KG nodes of the same type
  to prevent cross-heartbeat duplicates. A cap of 20 pending proposals per agent
  is enforced.

  ## Storage

  Phase 4: ETS-backed (in-memory, ephemeral)
  Phase 6+: Will migrate to Postgres via arbor_persistence

  ## Examples

      # Create a fact proposal
      {:ok, proposal} = Arbor.Memory.Proposal.create("agent_001", :fact, %{
        content: "User prefers short responses",
        confidence: 0.8,
        source: "fact_extractor"
      })

      # List pending proposals
      {:ok, proposals} = Arbor.Memory.Proposal.list_pending("agent_001")

      # Accept a proposal
      {:ok, node_id} = Arbor.Memory.Proposal.accept("agent_001", proposal.id)
  """

  alias Arbor.Memory.{Events, KnowledgeGraph, SelfKnowledge, Signals}

  require Logger

  @type proposal_type ::
          :fact
          | :insight
          | :learning
          | :pattern
          | :preconscious
          # Phase 3: heartbeat proposal types
          | :goal
          | :goal_update
          | :thought
          | :concern
          | :curiosity
          | :identity
          | :intent
          | :cognitive_mode
  @type proposal_status :: :pending | :accepted | :rejected | :deferred

  @type t :: %__MODULE__{
          id: String.t(),
          agent_id: String.t(),
          type: proposal_type(),
          content: String.t(),
          confidence: float(),
          source: String.t() | nil,
          evidence: [String.t()],
          metadata: map(),
          created_at: DateTime.t(),
          status: proposal_status()
        }

  @enforce_keys [:id, :agent_id, :type, :content]
  defstruct [
    :id,
    :agent_id,
    :type,
    :content,
    confidence: 0.5,
    source: nil,
    evidence: [],
    metadata: %{},
    created_at: nil,
    status: :pending
  ]

  # ETS table name for proposal storage
  @proposals_ets :arbor_memory_proposals

  # Confidence boost when a proposal is accepted
  @acceptance_boost 0.2

  # Maximum pending proposals per agent before oldest are pruned
  @max_pending 20

  # Similarity threshold for content dedup (Jaccard + containment)
  @content_similarity_threshold 0.6

  @allowed_types [
    :fact,
    :insight,
    :learning,
    :pattern,
    :preconscious,
    # Phase 3: heartbeat proposal types
    :goal,
    :goal_update,
    :thought,
    :concern,
    :curiosity,
    :identity,
    :intent,
    :cognitive_mode
  ]

  # ============================================================================
  # Construction
  # ============================================================================

  @doc """
  Create a new proposal for agent review.

  Deduplicates against existing pending/deferred proposals of the same type.
  If a similar proposal already exists, boosts its confidence instead of
  creating a duplicate. Enforces a cap of #{@max_pending} pending proposals
  per agent.

  ## Data Fields

  - `:content` - The proposed knowledge (required)
  - `:confidence` - How confident the detector is (0.0-1.0, default: 0.5)
  - `:source` - What generated this proposal (optional)
  - `:evidence` - Supporting observations (optional, list of strings)
  - `:metadata` - Additional data (optional)

  ## Examples

      {:ok, proposal} = Proposal.create("agent_001", :fact, %{
        content: "User prefers dark mode",
        confidence: 0.9,
        source: "fact_extractor",
        evidence: ["Mentioned dark mode 3 times", "Set system theme to dark"]
      })
  """
  @spec create(String.t(), proposal_type(), map()) :: {:ok, t()} | {:error, term()}
  def create(agent_id, type, data) when type in @allowed_types do
    with {:ok, content} <- validate_content(data) do
      ensure_table_exists()

      # Check for duplicate content among pending/deferred proposals
      case find_similar_pending(agent_id, type, content) do
        {:duplicate, existing} ->
          # Boost confidence of existing proposal instead of creating duplicate
          boosted = %{existing | confidence: min(1.0, existing.confidence + 0.05)}
          :ets.insert(@proposals_ets, {{agent_id, existing.id}, boosted})
          {:ok, existing}

        :no_duplicate ->
          # Cross-check against existing KG nodes to prevent cross-heartbeat duplication
          case find_similar_in_graph(agent_id, type, content) do
            {:duplicate, node_id} ->
              boost_existing_node(agent_id, node_id)
              {:ok, :reinforced}

            :new ->
              proposal = %__MODULE__{
                id: generate_id(),
                agent_id: agent_id,
                type: type,
                content: content,
                confidence: Map.get(data, :confidence, 0.5),
                source: Map.get(data, :source),
                evidence: Map.get(data, :evidence, []),
                metadata: Map.get(data, :metadata, %{}),
                created_at: DateTime.utc_now(),
                status: :pending
              }

              # Enforce pending queue cap — prune oldest low-confidence proposals
              enforce_pending_cap(agent_id)

              # Store in ETS
              :ets.insert(@proposals_ets, {{agent_id, proposal.id}, proposal})

              # Emit signal
              Signals.emit_proposal_created(agent_id, proposal)

              {:ok, proposal}
          end
      end
    end
  end

  def create(_agent_id, type, _data) do
    {:error, {:invalid_type, type, @allowed_types}}
  end

  # ============================================================================
  # Query Functions
  # ============================================================================

  @doc """
  List pending proposals for an agent.

  ## Options

  - `:type` - Filter by proposal type
  - `:limit` - Maximum proposals to return
  - `:sort_by` - Sort by: `:created_at` (default), `:confidence`

  ## Examples

      {:ok, proposals} = Proposal.list_pending("agent_001")
      {:ok, facts} = Proposal.list_pending("agent_001", type: :fact)
  """
  @spec list_pending(String.t(), keyword()) :: {:ok, [t()]}
  def list_pending(agent_id, opts \\ []) do
    ensure_table_exists()

    type_filter = Keyword.get(opts, :type)
    limit = Keyword.get(opts, :limit)
    sort_by = Keyword.get(opts, :sort_by, :created_at)

    proposals =
      @proposals_ets
      |> :ets.match_object({{agent_id, :_}, :_})
      |> Enum.map(fn {_key, proposal} -> proposal end)
      |> Enum.filter(&(&1.status == :pending))
      |> maybe_filter_type(type_filter)
      |> sort_proposals(sort_by)
      |> maybe_limit(limit)

    {:ok, proposals}
  end

  @doc """
  Get a specific proposal by ID.

  ## Examples

      {:ok, proposal} = Proposal.get("agent_001", "prop_abc123")
  """
  @spec get(String.t(), String.t()) :: {:ok, t()} | {:error, :not_found}
  def get(agent_id, proposal_id) do
    ensure_table_exists()

    case :ets.lookup(@proposals_ets, {agent_id, proposal_id}) do
      [{_key, proposal}] -> {:ok, proposal}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Count pending proposals for an agent.

  ## Options

  - `:type` - Filter by proposal type
  """
  @spec count_pending(String.t(), keyword()) :: non_neg_integer()
  def count_pending(agent_id, opts \\ []) do
    {:ok, proposals} = list_pending(agent_id, opts)
    length(proposals)
  end

  # ============================================================================
  # Agent Decision Functions
  # ============================================================================

  @doc """
  Accept a proposal and integrate it into the knowledge graph.

  The proposal is removed from the queue and its content is added as a
  knowledge graph node with a confidence boost.

  Returns `{:ok, node_id}` where node_id is the new KnowledgeGraph node.

  ## Examples

      {:ok, node_id} = Proposal.accept("agent_001", "prop_abc123")
  """
  @spec accept(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def accept(agent_id, proposal_id) do
    with {:ok, proposal} <- get(agent_id, proposal_id),
         :ok <- validate_status(proposal, :pending) do
      result =
        case route_for_type(proposal.type) do
          :kg_only ->
            # Original behavior: add directly to KG
            with {:ok, graph} <- get_graph(agent_id),
                 {:ok, new_graph, node_id} <- add_to_graph(graph, proposal) do
              save_graph(agent_id, new_graph)
              {:ok, node_id}
            end

          {:domain_store, store_fn} ->
            # Write to domain store, then create KG reference
            with {:ok, domain_key} <- store_fn.(agent_id, proposal),
                 {:ok, graph} <- get_graph(agent_id),
                 {:ok, new_graph, node_id} <- add_reference_node(graph, proposal, domain_key) do
              save_graph(agent_id, new_graph)
              {:ok, node_id}
            end
        end

      case result do
        {:ok, node_id} ->
          updated_proposal = %{proposal | status: :accepted}
          :ets.insert(@proposals_ets, {{agent_id, proposal_id}, updated_proposal})

          Events.record_proposal_accepted(agent_id, proposal_id, node_id, proposal.type)
          Signals.emit_proposal_accepted(agent_id, proposal_id, node_id)

          {:ok, node_id}

        error ->
          error
      end
    end
  end

  @doc """
  Reject a proposal.

  The proposal is marked as rejected and kept for calibration purposes.
  Future detection can learn from rejections to improve proposal quality.

  ## Options

  - `:reason` - Why the proposal was rejected

  ## Examples

      :ok = Proposal.reject("agent_001", "prop_abc123", reason: "Not accurate")
  """
  @spec reject(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def reject(agent_id, proposal_id, opts \\ []) do
    with {:ok, proposal} <- get(agent_id, proposal_id),
         :ok <- validate_status(proposal, :pending) do
      reason = Keyword.get(opts, :reason)

      # Update proposal status
      updated_proposal = %{
        proposal
        | status: :rejected,
          metadata: Map.put(proposal.metadata, :rejection_reason, reason)
      }

      :ets.insert(@proposals_ets, {{agent_id, proposal_id}, updated_proposal})

      # Emit events for calibration
      Events.record_pending_rejected(agent_id, proposal_id, proposal.type, reason)
      Signals.emit_proposal_rejected(agent_id, proposal_id, proposal.type, reason)

      :ok
    end
  end

  @doc """
  Defer a proposal for later review.

  The proposal stays in the queue but is marked as seen.

  ## Examples

      :ok = Proposal.defer("agent_001", "prop_abc123")
  """
  @spec defer(String.t(), String.t()) :: :ok | {:error, term()}
  def defer(agent_id, proposal_id) do
    with {:ok, proposal} <- get(agent_id, proposal_id),
         :ok <- validate_status(proposal, :pending) do
      # Update metadata to track deferral
      updated_proposal = %{
        proposal
        | status: :deferred,
          metadata:
            Map.merge(proposal.metadata, %{
              deferred_at: DateTime.utc_now(),
              deferred_count: Map.get(proposal.metadata, :deferred_count, 0) + 1
            })
      }

      :ets.insert(@proposals_ets, {{agent_id, proposal_id}, updated_proposal})

      Signals.emit_proposal_deferred(agent_id, proposal_id)

      :ok
    end
  end

  @doc """
  Undefer a proposal, returning it to pending status.

  ## Examples

      :ok = Proposal.undefer("agent_001", "prop_abc123")
  """
  @spec undefer(String.t(), String.t()) :: :ok | {:error, term()}
  def undefer(agent_id, proposal_id) do
    with {:ok, proposal} <- get(agent_id, proposal_id),
         :ok <- validate_status(proposal, :deferred) do
      updated_proposal = %{proposal | status: :pending}
      :ets.insert(@proposals_ets, {{agent_id, proposal_id}, updated_proposal})
      :ok
    end
  end

  @doc """
  Accept all pending proposals, optionally filtered by type.

  Returns a list of `{proposal_id, node_id}` tuples for accepted proposals.

  ## Examples

      {:ok, results} = Proposal.accept_all("agent_001")
      {:ok, results} = Proposal.accept_all("agent_001", :fact)
  """
  @spec accept_all(String.t(), proposal_type() | nil) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def accept_all(agent_id, type \\ nil) do
    opts = if type, do: [type: type], else: []

    with {:ok, proposals} <- list_pending(agent_id, opts) do
      results =
        proposals
        |> Enum.map(fn proposal ->
          case accept(agent_id, proposal.id) do
            {:ok, node_id} -> {:ok, {proposal.id, node_id}}
            error -> error
          end
        end)
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, result} -> result end)

      {:ok, results}
    end
  end

  @doc """
  Delete a proposal entirely (admin operation).

  Unlike reject, this completely removes the proposal without calibration.
  """
  @spec delete(String.t(), String.t()) :: :ok | {:error, :not_found}
  def delete(agent_id, proposal_id) do
    ensure_table_exists()

    case :ets.lookup(@proposals_ets, {agent_id, proposal_id}) do
      [{_key, _proposal}] ->
        :ets.delete(@proposals_ets, {agent_id, proposal_id})
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Delete all proposals for an agent.

  Called during agent cleanup.
  """
  @spec delete_all(String.t()) :: :ok
  def delete_all(agent_id) do
    ensure_table_exists()

    @proposals_ets
    |> :ets.match_object({{agent_id, :_}, :_})
    |> Enum.each(fn {key, _} -> :ets.delete(@proposals_ets, key) end)

    :ok
  end

  # ============================================================================
  # Statistics
  # ============================================================================

  @doc """
  Get statistics about proposals for an agent.
  """
  @spec stats(String.t()) :: map()
  def stats(agent_id) do
    ensure_table_exists()

    all_proposals =
      @proposals_ets
      |> :ets.match_object({{agent_id, :_}, :_})
      |> Enum.map(fn {_key, proposal} -> proposal end)

    by_status = Enum.group_by(all_proposals, & &1.status)
    by_type = Enum.group_by(all_proposals, & &1.type)

    %{
      total: length(all_proposals),
      pending: length(Map.get(by_status, :pending, [])),
      accepted: length(Map.get(by_status, :accepted, [])),
      rejected: length(Map.get(by_status, :rejected, [])),
      deferred: length(Map.get(by_status, :deferred, [])),
      by_type:
        Map.new(by_type, fn {type, proposals} ->
          {type, length(proposals)}
        end),
      avg_confidence: avg_confidence(all_proposals)
    }
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp ensure_table_exists do
    if :ets.whereis(@proposals_ets) == :undefined do
      try do
        :ets.new(@proposals_ets, [:named_table, :public, :set])
      rescue
        ArgumentError ->
          # Table was created by another process between our check and creation
          :ok
      end
    end
  end

  defp generate_id do
    "prop_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp validate_content(%{content: content}) when is_binary(content) and content != "" do
    {:ok, content}
  end

  defp validate_content(_), do: {:error, :missing_content}

  defp validate_status(proposal, expected) when proposal.status == expected, do: :ok

  defp validate_status(proposal, expected) do
    {:error, {:invalid_status, proposal.status, expected}}
  end

  defp maybe_filter_type(proposals, nil), do: proposals
  defp maybe_filter_type(proposals, type), do: Enum.filter(proposals, &(&1.type == type))

  defp sort_proposals(proposals, :created_at) do
    Enum.sort_by(proposals, & &1.created_at, {:desc, DateTime})
  end

  defp sort_proposals(proposals, :confidence) do
    Enum.sort_by(proposals, & &1.confidence, :desc)
  end

  defp maybe_limit(proposals, nil), do: proposals
  defp maybe_limit(proposals, limit), do: Enum.take(proposals, limit)

  defp avg_confidence([]), do: 0.0

  defp avg_confidence(proposals) do
    total = Enum.sum(Enum.map(proposals, & &1.confidence))
    Float.round(total / length(proposals), 3)
  end

  # ============================================================================
  # Deduplication
  # ============================================================================

  defp find_similar_pending(agent_id, type, content) do
    # Get pending and deferred proposals of the same type
    candidates =
      @proposals_ets
      |> :ets.match_object({{agent_id, :_}, :_})
      |> Enum.map(fn {_key, proposal} -> proposal end)
      |> Enum.filter(&(&1.type == type and &1.status in [:pending, :deferred]))

    content_lower = String.downcase(content)

    # Check exact match first (fast path)
    exact =
      Enum.find(candidates, fn p ->
        String.downcase(p.content) == content_lower
      end)

    case exact do
      nil -> fuzzy_match_duplicate(content, candidates)
      p -> {:duplicate, p}
    end
  end

  # Fuzzy match using word-set Jaccard + containment similarity
  # More robust than Jaro-Winkler for natural language (catches rewording)
  defp fuzzy_match_duplicate(content, candidates) do
    similar =
      Enum.find(candidates, fn p ->
        SelfKnowledge.text_similarity(content, p.content) >=
          @content_similarity_threshold
      end)

    case similar do
      nil -> :no_duplicate
      p -> {:duplicate, p}
    end
  end

  # Cross-check against existing KG nodes to prevent cross-heartbeat duplication.
  # After the pending queue is cleared (proposals accepted), the next heartbeat
  # may rediscover the same facts with slightly different wording.
  defp find_similar_in_graph(agent_id, type, content) do
    node_type = proposal_type_to_node_type(type)

    case get_graph(agent_id) do
      {:ok, graph} ->
        existing_nodes =
          graph.nodes
          |> Map.values()
          |> Enum.filter(&(Map.get(&1, :type) == node_type))

        similar =
          Enum.find(existing_nodes, fn node ->
            node_content = Map.get(node, :content, "")
            SelfKnowledge.text_similarity(content, node_content) >= @content_similarity_threshold
          end)

        case similar do
          nil -> :new
          node -> {:duplicate, Map.get(node, :id)}
        end

      {:error, _} ->
        :new
    end
  rescue
    # ETS table may not exist in test environments
    ArgumentError -> :new
  end

  defp boost_existing_node(agent_id, node_id) do
    case get_graph(agent_id) do
      {:ok, graph} ->
        updated = KnowledgeGraph.boost_node(graph, node_id, 0.1)
        save_graph(agent_id, updated)

      {:error, _} ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp enforce_pending_cap(agent_id) do
    {:ok, pending} = list_pending(agent_id)

    if length(pending) >= @max_pending do
      # Remove lowest-confidence, oldest proposals to make room
      to_prune =
        pending
        |> Enum.sort_by(fn p -> {p.confidence, p.created_at} end, :asc)
        |> Enum.take(length(pending) - @max_pending + 1)

      Enum.each(to_prune, fn p ->
        :ets.delete(@proposals_ets, {agent_id, p.id})
      end)
    end
  end

  # Graph access - uses the same ETS table as the facade
  @graph_ets :arbor_memory_graphs

  defp get_graph(agent_id) do
    case :ets.lookup(@graph_ets, agent_id) do
      [{^agent_id, graph}] -> {:ok, graph}
      [] -> {:error, :graph_not_initialized}
    end
  end

  defp save_graph(agent_id, graph) do
    :ets.insert(@graph_ets, {agent_id, graph})
    :ok
  end

  # Convert proposal to knowledge graph node
  defp add_to_graph(graph, proposal) do
    node_type = proposal_type_to_node_type(proposal.type)
    boosted_confidence = min(1.0, proposal.confidence + @acceptance_boost)

    node_data = %{
      type: node_type,
      content: proposal.content,
      relevance: boosted_confidence,
      metadata:
        Map.merge(proposal.metadata, %{
          proposal_id: proposal.id,
          source: proposal.source,
          evidence: proposal.evidence,
          original_confidence: proposal.confidence
        })
    }

    KnowledgeGraph.add_node(graph, node_data)
  end

  # ============================================================================
  # Domain-Store Routing
  # ============================================================================

  defp route_for_type(type) when type in [:fact, :insight, :learning, :pattern, :preconscious],
    do: :kg_only

  defp route_for_type(:goal), do: {:domain_store, &store_goal/2}
  defp route_for_type(:goal_update), do: {:domain_store, &store_goal_update/2}
  defp route_for_type(:identity), do: {:domain_store, &store_identity/2}
  defp route_for_type(:intent), do: {:domain_store, &store_intent/2}
  # Observations and cognitive_mode go directly to KG
  defp route_for_type(_type), do: :kg_only

  # Domain store writers (all runtime bridges)
  defp store_goal(agent_id, proposal) do
    content = proposal.content || ""

    if String.trim(content) == "" do
      Logger.warning("Skipping blank goal proposal for #{agent_id}")
      {:error, :empty_description}
    else
      goal_data = Map.get(proposal.metadata, :goal_data, %{})

      if Code.ensure_loaded?(Arbor.Memory.GoalStore) do
        case apply(Arbor.Memory.GoalStore, :add_goal, [
               agent_id,
               content,
               [priority: Map.get(goal_data, "priority", :medium)]
             ]) do
          {:ok, goal} -> {:ok, Map.get(goal, :id, generate_id())}
          error -> error
        end
      else
        {:ok, "goal_" <> generate_id()}
      end
    end
  end

  defp store_goal_update(agent_id, proposal) do
    update_data = Map.get(proposal.metadata, :update_data, %{})
    goal_id = Map.get(update_data, "id")

    if goal_id && Code.ensure_loaded?(Arbor.Memory.GoalStore) do
      progress = Map.get(update_data, "progress")

      if progress do
        apply(Arbor.Memory.GoalStore, :update_goal_progress, [agent_id, goal_id, progress])
      end

      {:ok, goal_id}
    else
      {:ok, "goal_update_" <> generate_id()}
    end
  end

  defp store_identity(_agent_id, _proposal) do
    # SelfKnowledge is a struct without a GenServer store API.
    # Create KG :trait reference. Full SelfKnowledge wiring
    # requires a proper store API — tracked separately.
    {:ok, "identity_" <> generate_id()}
  end

  defp store_intent(agent_id, proposal) do
    decomp = Map.get(proposal.metadata, :decomposition, %{})

    if Code.ensure_loaded?(Arbor.Memory.IntentStore) &&
         Code.ensure_loaded?(Arbor.Contracts.Intent) do
      intent =
        apply(Arbor.Contracts.Intent, :capability_intent, [
          Map.get(decomp, "capability", "unknown"),
          Map.get(decomp, "op", "unknown"),
          Map.get(decomp, "target"),
          [description: proposal.content]
        ])

      case apply(Arbor.Memory.IntentStore, :record_intent, [agent_id, intent]) do
        {:ok, recorded} -> {:ok, Map.get(recorded, :id, intent.id)}
        error -> error
      end
    else
      {:ok, "intent_" <> generate_id()}
    end
  end

  # Reference node — pointer to domain store, not full data
  defp add_reference_node(graph, proposal, domain_key) do
    node_type = proposal_type_to_node_type(proposal.type)
    boosted_confidence = min(1.0, proposal.confidence + @acceptance_boost)

    node_data = %{
      type: node_type,
      content: truncate_content(proposal.content, 200),
      relevance: boosted_confidence,
      metadata:
        Map.merge(proposal.metadata, %{
          proposal_id: proposal.id,
          source: proposal.source,
          domain_store: domain_store_name(proposal.type),
          domain_key: domain_key,
          reference_only: true
        })
    }

    KnowledgeGraph.add_node(graph, node_data)
  end

  defp domain_store_name(t) when t in [:goal, :goal_update], do: "goals"
  defp domain_store_name(:identity), do: "self_knowledge"
  defp domain_store_name(:intent), do: "intents"

  defp truncate_content(content, max) do
    if String.length(content) > max do
      String.slice(content, 0, max) <> "..."
    else
      content
    end
  end

  defp proposal_type_to_node_type(:fact), do: :fact
  defp proposal_type_to_node_type(:insight), do: :insight
  defp proposal_type_to_node_type(:learning), do: :skill
  defp proposal_type_to_node_type(:pattern), do: :experience
  defp proposal_type_to_node_type(:preconscious), do: :experience
  # Phase 3 types — semantically precise KG node types
  defp proposal_type_to_node_type(:goal), do: :goal
  defp proposal_type_to_node_type(:goal_update), do: :goal
  defp proposal_type_to_node_type(:thought), do: :observation
  defp proposal_type_to_node_type(:concern), do: :observation
  defp proposal_type_to_node_type(:curiosity), do: :observation
  defp proposal_type_to_node_type(:identity), do: :trait
  defp proposal_type_to_node_type(:intent), do: :intention
  defp proposal_type_to_node_type(:cognitive_mode), do: :observation
end
