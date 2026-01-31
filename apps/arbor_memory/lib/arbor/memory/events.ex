defmodule Arbor.Memory.Events do
  @moduledoc """
  Permanent event logging for memory operations.

  Writes durable events to EventLog via arbor_persistence AND emits on the
  signal bus for real-time notification (dual-emit pattern).

  These are significant, queryable history records — different from the
  transient operational signals in `Arbor.Memory.Signals`.

  ## When to Use Events vs Signals

  | Use Case | Module |
  |----------|--------|
  | Operational notification (indexed, recalled) | Signals |
  | Queryable history (identity changed, milestone) | Events |
  | Audit trail | Events |
  | Real-time dashboard | Signals |
  | Crash recovery / state reconstruction | Events |

  ## Event Types

  | Event Type | Purpose |
  |------------|---------|
  | `:identity_changed` | Agent's identity/self-model was updated |
  | `:relationship_milestone` | Significant relationship event |
  | `:consolidation_completed` | Consolidation metrics for history |
  | `:self_insight_created` | New self-insight added to graph |
  | `:knowledge_milestone` | Knowledge graph milestone (e.g., 100 nodes) |

  ## Examples

      # Record an identity change
      :ok = Arbor.Memory.Events.record_identity_changed("agent_001", %{
        field: "values",
        old_value: ["curiosity"],
        new_value: ["curiosity", "helpfulness"]
      })

      # Query history
      {:ok, events} = Arbor.Memory.Events.get_history("agent_001", limit: 50)
  """

  alias Arbor.Persistence.Event

  @event_log_name :memory_events
  @event_log_backend Arbor.Persistence.EventLog.ETS

  # ============================================================================
  # Event Recording (Dual-Emit)
  # ============================================================================

  @doc """
  Record an identity change event.

  Identity changes are significant — they represent evolution of the agent's
  self-model and should be tracked permanently.

  ## Change Data

  - `:field` - Which identity field changed
  - `:old_value` - Previous value
  - `:new_value` - New value
  - `:reason` - Why the change was made (optional)
  """
  @spec record_identity_changed(String.t(), map()) :: :ok | {:error, term()}
  def record_identity_changed(agent_id, change_data) do
    dual_emit(agent_id, :identity_changed, %{
      field: change_data[:field],
      old_value: change_data[:old_value],
      new_value: change_data[:new_value],
      reason: change_data[:reason]
    })
  end

  @doc """
  Record a relationship milestone.

  Relationship milestones mark significant moments in a relationship,
  such as first interaction, trust threshold reached, etc.

  ## Milestone Data

  - `:relationship_id` - The relationship identifier
  - `:person` - Person name (optional)
  - `:milestone` - Type of milestone
  - `:details` - Additional details (optional)
  """
  @spec record_relationship_milestone(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def record_relationship_milestone(agent_id, relationship_id, milestone_data) do
    dual_emit(agent_id, :relationship_milestone, %{
      relationship_id: relationship_id,
      person: milestone_data[:person],
      milestone: milestone_data[:milestone],
      details: milestone_data[:details]
    })
  end

  @doc """
  Record consolidation completion with metrics.

  This creates a permanent record of consolidation for trend analysis
  and debugging memory behavior over time.

  ## Metrics

  - `:decayed_count` - Number of nodes that had relevance reduced
  - `:pruned_count` - Number of nodes removed
  - `:duration_ms` - How long consolidation took
  - `:total_nodes` - Total nodes after consolidation
  """
  @spec record_consolidation_completed(String.t(), map()) :: :ok | {:error, term()}
  def record_consolidation_completed(agent_id, metrics) do
    dual_emit(agent_id, :consolidation_completed, %{
      decayed_count: metrics[:decayed_count],
      pruned_count: metrics[:pruned_count],
      duration_ms: metrics[:duration_ms],
      total_nodes: metrics[:total_nodes],
      average_relevance: metrics[:average_relevance]
    })
  end

  @doc """
  Record creation of a self-insight.

  Self-insights are significant introspective discoveries that should
  be tracked for identity evolution analysis.

  ## Insight Data

  - `:node_id` - The knowledge graph node ID
  - `:content` - The insight content
  - `:confidence` - How confident the agent is in this insight
  - `:source` - What triggered this insight (optional)
  """
  @spec record_self_insight_created(String.t(), map()) :: :ok | {:error, term()}
  def record_self_insight_created(agent_id, insight_data) do
    dual_emit(agent_id, :self_insight_created, %{
      node_id: insight_data[:node_id],
      content_preview: String.slice(insight_data[:content] || "", 0, 200),
      confidence: insight_data[:confidence],
      source: insight_data[:source]
    })
  end

  @doc """
  Record a knowledge graph milestone.

  Milestones track growth of the agent's knowledge over time.

  ## Milestone Types

  - `:node_count_reached` - Hit a node count threshold
  - `:type_quota_reached` - Hit quota for a node type
  - `:first_connection` - First edge added
  """
  @spec record_knowledge_milestone(String.t(), atom(), map()) :: :ok | {:error, term()}
  def record_knowledge_milestone(agent_id, milestone_type, data) do
    dual_emit(agent_id, :knowledge_milestone, %{
      milestone_type: milestone_type,
      data: data
    })
  end

  @doc """
  Record approval of a pending item.

  Tracks the agent's decision to accept a proposed fact or learning.
  """
  @spec record_pending_approved(String.t(), String.t(), String.t(), atom()) ::
          :ok | {:error, term()}
  def record_pending_approved(agent_id, pending_id, node_id, pending_type) do
    dual_emit(agent_id, :pending_approved, %{
      pending_id: pending_id,
      node_id: node_id,
      pending_type: pending_type
    })
  end

  @doc """
  Record rejection of a pending item.

  Tracks the agent's decision to reject a proposed fact or learning.
  """
  @spec record_pending_rejected(String.t(), String.t(), atom(), String.t() | nil) ::
          :ok | {:error, term()}
  def record_pending_rejected(agent_id, pending_id, pending_type, reason \\ nil) do
    dual_emit(agent_id, :pending_rejected, %{
      pending_id: pending_id,
      pending_type: pending_type,
      reason: reason
    })
  end

  # ============================================================================
  # Query Helpers
  # ============================================================================

  @doc """
  Get event history for an agent.

  ## Options

  - `:limit` - Maximum events to return
  - `:from` - Start from this event number
  - `:direction` - `:forward` (oldest first) or `:backward` (newest first)
  """
  @spec get_history(String.t(), keyword()) :: {:ok, [Event.t()]} | {:error, term()}
  def get_history(agent_id, opts \\ []) do
    stream_id = stream_id(agent_id)

    Arbor.Persistence.read_stream(
      @event_log_name,
      @event_log_backend,
      stream_id,
      opts
    )
  end

  @doc """
  Get events of a specific type for an agent.

  ## Examples

      {:ok, changes} = Arbor.Memory.Events.get_by_type("agent_001", :identity_changed)
  """
  @spec get_by_type(String.t(), atom(), keyword()) :: {:ok, [Event.t()]} | {:error, term()}
  def get_by_type(agent_id, event_type, opts \\ []) do
    type_string = to_string(event_type)

    case get_history(agent_id, opts) do
      {:ok, events} ->
        filtered =
          Enum.filter(events, fn event ->
            to_string(event.type) == type_string
          end)

        {:ok, filtered}

      error ->
        error
    end
  end

  @doc """
  Get the most recent events for an agent.

  Convenience function that returns events in reverse chronological order.
  """
  @spec get_recent(String.t(), non_neg_integer()) :: {:ok, [Event.t()]} | {:error, term()}
  def get_recent(agent_id, limit \\ 10) do
    case get_history(agent_id, direction: :backward, limit: limit) do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      error -> error
    end
  end

  @doc """
  Count events of a specific type for an agent.
  """
  @spec count_by_type(String.t(), atom()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count_by_type(agent_id, event_type) do
    case get_by_type(agent_id, event_type) do
      {:ok, events} -> {:ok, length(events)}
      error -> error
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Dual-emit: write to EventLog AND emit on signal bus
  defp dual_emit(agent_id, event_type, data) do
    stream_id = stream_id(agent_id)

    event =
      Event.new(
        stream_id,
        to_string(event_type),
        Map.merge(data, %{
          agent_id: agent_id
        })
      )

    # Write to EventLog
    result =
      Arbor.Persistence.append(
        @event_log_name,
        @event_log_backend,
        stream_id,
        event
      )

    # Also emit on signal bus for real-time notification
    Arbor.Signals.emit(
      :memory,
      event_type,
      Map.merge(data, %{
        agent_id: agent_id,
        permanent: true
      })
    )

    case result do
      {:ok, _events} -> :ok
      error -> error
    end
  end

  defp stream_id(agent_id) do
    "memory:#{agent_id}"
  end
end
