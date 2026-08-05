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

  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}
  alias Arbor.Memory.ArchiveReadView
  alias Arbor.Memory.Config
  alias Arbor.Persistence.Event

  @event_log_name :memory_events
  @event_log_backend Arbor.Persistence.EventLog.ETS
  @archive_append_attempts 2

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
  # Phase 3 Events (Consolidation and Relationships)
  # ============================================================================

  @doc """
  Record a knowledge node being archived (before pruning).

  This creates a permanent record so nothing is silently lost during consolidation.

  ## Data

  - `:node_id` - The node being archived
  - `:type` - Node type
  - `:content` - Node content
  - `:relevance` - Relevance at time of archive
  - `:created_at` - When node was created
  - `:last_accessed` - When node was last accessed
  - `:access_count` - Total access count
  - `:reason` - Why it was archived (:low_relevance, :quota_exceeded)
  """
  @spec record_knowledge_archived(String.t(), map()) :: :ok | {:error, term()}
  def record_knowledge_archived(agent_id, data) do
    dual_emit(agent_id, :knowledge_archived, %{
      node_id: data[:node_id],
      type: data[:type],
      content_preview: String.slice(data[:content] || "", 0, 200),
      relevance: data[:relevance],
      created_at: data[:created_at],
      last_accessed: data[:last_accessed],
      access_count: data[:access_count],
      reason: data[:reason]
    })
  end

  @doc false
  @spec archive_knowledge_once(String.t(), map(), DateTime.t()) :: :ok | {:error, term()}
  def archive_knowledge_once(
        agent_id,
        %{
          archive_payload: archive_payload,
          idempotency_key: idempotency_key,
          provenance_status: provenance_status,
          taint: %Taint{} = taint
        },
        %DateTime{} = occurred_at
      ) do
    archive_stream = stream_id(agent_id)

    with {:ok, target} <- Config.maintenance_archive_target(),
         :ok <- require_archive_durability(target),
         true <- provenance_status in [:verified, :legacy_unlabeled, :invalid_durable_provenance],
         {:ok, envelope} <- TaintEnvelope.new(archive_payload, taint),
         {:ok, envelope} <- TaintEnvelope.to_map(envelope),
         {:ok, event_id} <- archive_event_id(agent_id, archive_stream, idempotency_key),
         %Event{} = event <-
           Event.new(
             archive_stream,
             "knowledge_archived",
             %{
               "agent_id" => agent_id,
               "archive" => envelope,
               "provenance_status" => Atom.to_string(provenance_status)
             },
             id: event_id,
             timestamp: occurred_at,
             metadata: %{"source" => "knowledge_graph_maintenance"}
           ),
         :ok <-
           append_exact_archive(target, archive_stream, event, @archive_append_attempts) do
      :ok
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_archive_effect}
    end
  rescue
    _ -> {:error, :archive_sink_unavailable}
  catch
    _, _ -> {:error, :archive_sink_unavailable}
  end

  def archive_knowledge_once(_agent_id, _entry, _occurred_at),
    do: {:error, :invalid_archive_effect}

  @doc """
  Record a relationship being created.

  Creates a permanent record of new relationship establishment.
  """
  @spec record_relationship_created(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def record_relationship_created(agent_id, relationship_id, name) do
    dual_emit(agent_id, :relationship_created, %{
      relationship_id: relationship_id,
      name: name
    })
  end

  @doc """
  Record a significant relationship moment.

  Different from relationship_milestone — this records individual moments,
  while milestones mark aggregate achievements (100th interaction, etc.).
  """
  @spec record_relationship_moment(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def record_relationship_moment(agent_id, relationship_id, moment_data) do
    dual_emit(agent_id, :relationship_moment, %{
      relationship_id: relationship_id,
      summary: moment_data[:summary],
      emotional_markers: moment_data[:emotional_markers],
      salience: moment_data[:salience]
    })
  end

  # ============================================================================
  # Phase 4 Events (Proposals)
  # ============================================================================

  @doc """
  Record a proposal being accepted.

  Tracks the agent's decision to accept a proposed fact, insight, or learning.
  """
  @spec record_proposal_accepted(String.t(), String.t(), String.t(), atom()) ::
          :ok | {:error, term()}
  def record_proposal_accepted(agent_id, proposal_id, node_id, proposal_type) do
    dual_emit(agent_id, :proposal_accepted, %{
      proposal_id: proposal_id,
      node_id: node_id,
      proposal_type: proposal_type
    })
  end

  @doc """
  Record an insight being created from a proposal.

  Tracks insights that have been accepted and integrated into the knowledge graph.
  """
  @spec record_insight_created(String.t(), map()) :: :ok | {:error, term()}
  def record_insight_created(agent_id, insight_data) do
    dual_emit(agent_id, :insight_created, %{
      node_id: insight_data[:node_id],
      category: insight_data[:category],
      content_preview: String.slice(insight_data[:content] || "", 0, 200),
      confidence: insight_data[:confidence],
      source: insight_data[:source]
    })
  end

  @doc """
  Record a learning being integrated from a proposal.

  Tracks learnings that have been accepted and integrated into the knowledge graph.
  """
  @spec record_learning_integrated(String.t(), map()) :: :ok | {:error, term()}
  def record_learning_integrated(agent_id, learning_data) do
    dual_emit(agent_id, :learning_integrated, %{
      node_id: learning_data[:node_id],
      pattern_type: learning_data[:pattern_type],
      content_preview: String.slice(learning_data[:content] || "", 0, 200),
      confidence: learning_data[:confidence],
      tools: learning_data[:tools]
    })
  end

  # ============================================================================
  # Phase 5 Events (Identity & Self-Model)
  # ============================================================================

  @doc """
  Record a reflection being completed.

  Tracks structured self-analysis events.
  """
  @spec record_reflection_completed(String.t(), map()) :: :ok | {:error, term()}
  def record_reflection_completed(agent_id, reflection_data) do
    dual_emit(agent_id, :reflection_completed, %{
      reflection_id: reflection_data[:reflection_id],
      prompt: reflection_data[:prompt],
      insight_count: reflection_data[:insight_count]
    })
  end

  # ============================================================================
  # Query Helpers
  # ============================================================================

  @doc """
  Get event history for an agent.

  ## Options

  - `:limit` - Maximum events to return (default 100, capped at 1,000)
  - `:direction` - `:forward` (oldest first) or `:backward` (newest first)

  This convenience API returns the first bounded page. Independent source
  event numbers are deliberately not exposed as one integer cursor. Use
  `get_history_page/2` to traverse a stable snapshot; `from: 0` remains a
  first-page compatibility value, while positive integer offsets are rejected.
  """
  @spec get_history(String.t(), keyword()) :: {:ok, [Event.t()]} | {:error, term()}
  def get_history(agent_id, opts \\ []) do
    with {:ok, read} <- ArchiveReadView.normalize_options(opts),
         true <- is_nil(read.cursor),
         {:ok, page} <- read_archive_page(agent_id, read) do
      {:ok, page.events}
    else
      false -> {:error, :invalid_archive_read_options}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Read one page from a stable two-source history snapshot.

  The returned opaque `next_cursor` records each source's initial high-water
  mark, direction, current epoch, and source-local position. Forward pages
  traverse legacy then durable; backward pages traverse durable then legacy.
  Events appended after the first page are excluded from that cursor's snapshot.
  """
  @spec get_history_page(String.t(), keyword()) ::
          {:ok, %{events: [Event.t()], next_cursor: ArchiveReadView.Cursor.t() | nil}}
          | {:error, term()}
  def get_history_page(agent_id, opts \\ []) do
    with {:ok, read} <- ArchiveReadView.normalize_options(opts) do
      read_archive_page(agent_id, read)
    end
  end

  @doc """
  Get events of a specific type for an agent.

  ## Examples

      {:ok, changes} = Arbor.Memory.Events.get_by_type("agent_001", :identity_changed)

  `:limit` applies after type filtering. At most 1,000 source records are
  inspected by this first-page convenience call.
  """
  @spec get_by_type(String.t(), atom(), keyword()) :: {:ok, [Event.t()]} | {:error, term()}
  def get_by_type(agent_id, event_type, opts \\ [])

  def get_by_type(agent_id, event_type, opts) when is_atom(event_type) do
    with {:ok, read} <- ArchiveReadView.normalize_options(opts),
         true <- is_nil(read.cursor),
         {:ok, page} <- read_archive_page(agent_id, read, event_type) do
      {:ok, page.events}
    else
      false -> {:error, :invalid_archive_read_options}
      {:error, _reason} = error -> error
    end
  end

  def get_by_type(_agent_id, _event_type, _opts),
    do: {:error, :invalid_archive_read_options}

  @doc "Read one stable snapshot page filtered to an event type."
  @spec get_by_type_page(String.t(), atom(), keyword()) ::
          {:ok, %{events: [Event.t()], next_cursor: ArchiveReadView.Cursor.t() | nil}}
          | {:error, term()}
  def get_by_type_page(agent_id, event_type, opts \\ [])

  def get_by_type_page(agent_id, event_type, opts) when is_atom(event_type) do
    with {:ok, read} <- ArchiveReadView.normalize_options(opts) do
      read_archive_page(agent_id, read, event_type)
    end
  end

  def get_by_type_page(_agent_id, _event_type, _opts),
    do: {:error, :invalid_archive_read_options}

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
  Count every distinct event of a specific type in a stable source snapshot.
  """
  @spec count_by_type(String.t(), atom()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count_by_type(agent_id, event_type) when is_atom(event_type),
    do: count_type_pages(agent_id, event_type, nil, 0)

  def count_by_type(_agent_id, _event_type), do: {:error, :invalid_archive_read_options}

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp read_archive_page(agent_id, read, event_type \\ nil) do
    expected_stream_id = stream_id(agent_id)

    with {:ok, target} <- Config.maintenance_archive_target(),
         {:ok, cursor} <- prepare_archive_cursor(read, expected_stream_id, event_type, target),
         {:ok, events, next_cursor} <-
           collect_archive_page(cursor, target, event_type, read.limit) do
      {:ok, %{events: events, next_cursor: next_cursor}}
    else
      {:error, :invalid_archive_cursor} = error -> error
      {:error, :invalid_archive_read_options} = error -> error
      {:error, :archive_event_conflict} = error -> error
      _backend_or_projection_failure -> {:error, :archive_read_unavailable}
    end
  rescue
    _error -> {:error, :archive_read_unavailable}
  catch
    _kind, _reason -> {:error, :archive_read_unavailable}
  end

  defp prepare_archive_cursor(%ArchiveReadView{cursor: nil} = read, stream_id, event_type, target) do
    with {:ok, heads} <- read_source_heads(target, stream_id) do
      {:ok, ArchiveReadView.new_cursor(stream_id, event_type, read.direction, target, heads)}
    end
  end

  defp prepare_archive_cursor(%ArchiveReadView{cursor: cursor}, stream_id, event_type, target) do
    with {:ok, cursor} <- ArchiveReadView.validate_cursor(cursor, stream_id, event_type, target),
         true <- cursor.direction in [:forward, :backward],
         {:ok, current_heads} <- read_source_heads(target, stream_id),
         true <-
           current_heads.legacy >= cursor.legacy_head and
             current_heads.durable >= cursor.durable_head do
      {:ok, cursor}
    else
      {:error, :invalid_archive_cursor} = error -> error
      _invalid_or_rewound_source -> {:error, :archive_read_unavailable}
    end
  end

  defp read_source_heads(target, stream_id) do
    legacy = legacy_target()

    with {:ok, legacy_head} <- read_source_head(legacy, stream_id),
         {:ok, durable_head} <- read_durable_head(target, stream_id) do
      {:ok, %{legacy: legacy_head, durable: durable_head}}
    end
  end

  defp read_durable_head(target, stream_id) do
    if ArchiveReadView.same_target?(target),
      do: {:ok, 0},
      else: read_source_head(target, stream_id)
  end

  defp read_source_head(target, stream_id) do
    case Arbor.Persistence.stream_version(
           target.name,
           target.backend,
           stream_id,
           target.opts
         ) do
      {:ok, version} when is_integer(version) and version >= 0 -> {:ok, version}
      _invalid_or_failed -> {:error, :archive_read_unavailable}
    end
  end

  defp collect_archive_page(cursor, target, event_type, limit) do
    collect_archive_page(
      cursor,
      target,
      event_type,
      limit,
      ArchiveReadView.max_limit(),
      []
    )
  end

  defp collect_archive_page(cursor, _target, _event_type, 0, _scan_left, events) do
    {:ok, Enum.reverse(events), ArchiveReadView.next_cursor(cursor)}
  end

  defp collect_archive_page(cursor, _target, _event_type, _remaining, 0, events) do
    {:ok, Enum.reverse(events), ArchiveReadView.next_cursor(cursor)}
  end

  defp collect_archive_page(cursor, target, event_type, remaining, scan_left, events) do
    request_limit = min(remaining, scan_left)

    case ArchiveReadView.source_range(cursor, request_limit) do
      :done ->
        {:ok, Enum.reverse(events), nil}

      {:ok, source, range_opts, requested} ->
        with {:ok, source_events} <-
               read_source_range(source, target, cursor.stream_id, range_opts, requested),
             {:ok, accepted} <-
               accept_source_events(source_events, source, target, cursor, event_type) do
          next_cursor = ArchiveReadView.advance(cursor, source, source_events)

          collect_archive_page(
            next_cursor,
            target,
            event_type,
            remaining - length(accepted),
            scan_left - length(source_events),
            Enum.reverse(accepted, events)
          )
        end
    end
  end

  defp read_source_range(source, target, stream_id, range_opts, requested) do
    source_target = if source == :legacy, do: legacy_target(), else: target
    opts = Keyword.merge(source_target.opts, range_opts)

    case Arbor.Persistence.read_stream_range(
           source_target.name,
           source_target.backend,
           stream_id,
           opts
         ) do
      {:ok, events} when is_list(events) and length(events) <= requested ->
        if valid_source_page?(events, stream_id, range_opts) and
             not (events == [] and range_has_events?(range_opts)) do
          {:ok, events}
        else
          {:error, :archive_read_unavailable}
        end

      _invalid_or_failed ->
        {:error, :archive_read_unavailable}
    end
  end

  defp accept_source_events(events, source, target, cursor, event_type) do
    Enum.reduce_while(events, {:ok, []}, fn event, {:ok, accepted} ->
      case event_identity_decision(source, event, target, cursor.stream_id) do
        :include ->
          accepted =
            if visible_event?(event, source, event_type),
              do: [event | accepted],
              else: accepted

          {:cont, {:ok, accepted}}

        :duplicate_projection ->
          {:cont, {:ok, accepted}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, accepted} -> {:ok, Enum.reverse(accepted)}
      {:error, _reason} = error -> error
    end
  end

  defp event_identity_decision(source, event, target, stream_id) do
    if ArchiveReadView.same_target?(target) do
      :include
    else
      counterpart = if source == :legacy, do: target, else: legacy_target()
      fingerprint = Arbor.Persistence.EventLog.event_fingerprint(stream_id, event)

      case read_counterpart_identity(counterpart, stream_id, event.id) do
        {:ok, nil} when is_binary(fingerprint) ->
          :include

        {:ok, ^fingerprint} when source == :legacy ->
          :include

        {:ok, ^fingerprint} when source == :durable ->
          :duplicate_projection

        {:ok, _different_or_invalid} ->
          {:error, :archive_event_conflict}

        {:error, _reason} ->
          {:error, :archive_read_unavailable}
      end
    end
  end

  defp read_counterpart_identity(target, stream_id, event_id) do
    case Arbor.Persistence.event_identity(
           target.name,
           target.backend,
           stream_id,
           event_id,
           target.opts
         ) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, fingerprint} when is_binary(fingerprint) and byte_size(fingerprint) == 64 ->
        {:ok, fingerprint}

      _invalid_or_failed ->
        {:error, :archive_read_unavailable}
    end
  end

  defp count_type_pages(agent_id, event_type, cursor, count) do
    opts =
      [limit: ArchiveReadView.max_limit(), direction: :forward]
      |> then(fn opts -> if cursor, do: Keyword.put(opts, :cursor, cursor), else: opts end)

    case get_by_type_page(agent_id, event_type, opts) do
      {:ok, %{events: events, next_cursor: nil}} ->
        {:ok, count + length(events)}

      {:ok, %{events: events, next_cursor: next_cursor}} when next_cursor != cursor ->
        count_type_pages(agent_id, event_type, next_cursor, count + length(events))

      {:ok, %{next_cursor: ^cursor}} ->
        {:error, :archive_read_unavailable}

      {:error, _reason} = error ->
        error
    end
  end

  defp valid_source_page?(events, expected_stream_id, opts) do
    from = Keyword.fetch!(opts, :from)
    to = Keyword.fetch!(opts, :to)
    direction = Keyword.fetch!(opts, :direction)

    numbers = Enum.map(events, &Map.get(&1, :event_number))

    Enum.all?(events, &valid_source_event?(&1, expected_stream_id, from, to)) and
      length(numbers) == MapSet.size(MapSet.new(numbers)) and
      ordered_event_numbers?(numbers, direction)
  end

  defp valid_source_event?(
         %Event{id: id, stream_id: stream_id, type: type, event_number: event_number},
         expected_stream_id,
         from,
         to
       ) do
    is_binary(id) and id != "" and stream_id == expected_stream_id and is_binary(type) and
      is_integer(event_number) and event_number >= from and event_number <= to
  end

  defp valid_source_event?(_event, _expected_stream_id, _from, _to), do: false

  defp ordered_event_numbers?(numbers, :forward), do: numbers == Enum.sort(numbers)
  defp ordered_event_numbers?(numbers, :backward), do: numbers == Enum.sort(numbers, :desc)

  defp range_has_events?(opts),
    do: Keyword.fetch!(opts, :from) <= Keyword.fetch!(opts, :to)

  defp visible_event?(%Event{type: type}, source, event_type) do
    source_visible = source == :legacy or type == "knowledge_archived"
    type_visible = is_nil(event_type) or type == Atom.to_string(event_type)
    source_visible and type_visible
  end

  defp legacy_target do
    %{name: @event_log_name, backend: @event_log_backend, opts: []}
  end

  defp archive_event_id(agent_id, stream_id, {operation_id, node_id, reason})
       when is_binary(agent_id) and is_binary(stream_id) and is_binary(operation_id) and
              is_binary(node_id) and is_atom(reason) do
    digest =
      {:knowledge_graph_archive, agent_id, stream_id, operation_id, node_id, reason}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    {:ok, "evt_kg_archive_#{digest}"}
  rescue
    _ -> {:error, :invalid_archive_effect}
  catch
    _, _ -> {:error, :invalid_archive_effect}
  end

  defp archive_event_id(_agent_id, _stream_id, _identity),
    do: {:error, :invalid_archive_effect}

  defp append_exact_archive(_target, _stream_id, _event, 0),
    do: {:error, :archive_outcome_unknown}

  defp append_exact_archive(target, stream_id, event, attempts) do
    case Arbor.Persistence.append(
           target.name,
           target.backend,
           stream_id,
           event,
           target.opts
         ) do
      {:ok, [%Event{id: event_id}]} when event_id == event.id ->
        :ok

      {:error, {:append_indeterminate, operation}} ->
        reconcile_archive_append(target, stream_id, event, operation, attempts)

      {:error, _reason} = error ->
        error

      _ ->
        {:error, :archive_outcome_unknown}
    end
  end

  defp reconcile_archive_append(target, stream_id, event, operation, attempts) do
    case Arbor.Persistence.reconcile_append(
           target.name,
           target.backend,
           operation,
           target.opts
         ) do
      {:ok, {:committed, [%Event{id: event_id}]}} when event_id == event.id ->
        :ok

      {:ok, :absent} ->
        append_exact_archive(target, stream_id, event, attempts - 1)

      {:error, _reason} = error ->
        error

      _ ->
        {:error, :archive_outcome_unknown}
    end
  end

  defp require_archive_durability(target) do
    case Arbor.Persistence.durability_class(target.name, target.backend, target.opts) do
      {:ok, :node_restart} -> :ok
      {:ok, _weaker} -> {:error, :archive_sink_insufficient_durability}
      {:error, _reason} -> {:error, :archive_sink_durability_unknown}
      _ -> {:error, :archive_sink_durability_unknown}
    end
  rescue
    _ -> {:error, :archive_sink_durability_unknown}
  catch
    _, _ -> {:error, :archive_sink_durability_unknown}
  end

  # Dual-emit: write to the local :memory_events EventLog (for queries)
  # AND emit on the signal bus (for real-time + historian persistence).
  defp dual_emit(agent_id, event_type, data) do
    enriched_data = Map.put(data, :agent_id, agent_id)
    stream_id = stream_id(agent_id)

    # Write to the memory-local EventLog so get_history/get_by_type/etc. can read it back.
    event =
      Arbor.Persistence.Event.new(
        stream_id,
        to_string(event_type),
        enriched_data,
        metadata: %{source_node: node()}
      )

    if Process.whereis(@event_log_name) do
      Arbor.Persistence.append(@event_log_name, @event_log_backend, stream_id, event)
    end

    # Signal bus emit (real-time notification + historian/Postgres persistence)
    Arbor.Signals.durable_emit(:memory, event_type, enriched_data, stream_id: stream_id)

    :ok
  end

  defp stream_id(agent_id) do
    "memory:#{agent_id}"
  end
end
