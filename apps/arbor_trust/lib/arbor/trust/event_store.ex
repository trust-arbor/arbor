defmodule Arbor.Trust.EventStore do
  @moduledoc """
  Persistent storage for trust system events.

  The EventStore provides durable storage for all trust-affecting events,
  enabling historical analysis, debugging, and audit trails for the progressive
  trust system.

  ## Storage Architecture

  - `Persistence.EventLog.ETS` for durable event storage (unified event log)
  - ETS cache for fast indexed reads and recent events
  - Signals for event notification to other subsystems

  ## Query Capabilities

  - Get all events for an agent
  - Get events by type
  - Get events in a time range
  - Get aggregate statistics
  - Get tier progression history
  - Cross-agent queries for system-wide analysis

  ## Usage

      # Record an event
      :ok = EventStore.record_event(event)

      # Query events
      {:ok, events} = EventStore.get_events(agent_id: "agent_123")
      {:ok, events} = EventStore.get_events(event_type: :action_success)
      {:ok, events} = EventStore.get_events(agent_id: "agent_123", limit: 100)

      # Get agent timeline
      {:ok, timeline} = EventStore.get_agent_timeline("agent_123")

      # Get trust progression
      {:ok, progression} = EventStore.get_trust_progression("agent_123")

      # Get system-wide statistics
      {:ok, stats} = EventStore.get_system_stats()
  """

  use GenServer

  alias Arbor.Contracts.Trust.Event
  alias Arbor.Common.Pagination.Cursor
  alias Arbor.Trust.EventConverter
  alias Arbor.Persistence.EventLog.ETS, as: PersistenceETS

  require Logger

  @table_name :trust_events_store
  @index_table :trust_events_index
  @max_cached_events 20_000

  defstruct [
    :events_table,
    :index_table,
    :event_log,
    :stats
  ]

  # Client API

  @doc """
  Start the trust event store.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record a trust event.
  """
  @spec record_event(Event.t()) :: :ok | {:error, term()}
  def record_event(%Event{} = event) do
    GenServer.call(__MODULE__, {:record_event, event})
  end

  @doc """
  Record multiple events atomically.
  """
  @spec record_events([Event.t()]) :: :ok | {:error, term()}
  def record_events(events) when is_list(events) do
    GenServer.call(__MODULE__, {:record_events, events})
  end

  @type paginated_result :: %{
          events: [Event.t()],
          next_cursor: String.t() | nil,
          has_more: boolean()
        }

  @doc """
  Get events matching the given filters.

  ## Filters

  - `:agent_id` - Filter by agent ID
  - `:event_type` - Filter by event type
  - `:start_time` - Events after this time
  - `:end_time` - Events before this time
  - `:limit` - Maximum number of events to return
  - `:cursor` - Cursor for pagination (timestamp_ms:event_id format). Use for
    stable pagination when new events may be added.
  - `:order` - :asc or :desc (default :desc)

  ## Returns

  When `:cursor` is provided (even if nil), returns cursor-based paginated result:
  `{:ok, %{events: [Event.t()], next_cursor: string | nil, has_more: boolean}}`

  Otherwise returns simple list for backwards compatibility:
  `{:ok, [Event.t()]}`
  """
  @spec get_events(keyword()) ::
          {:ok, [Event.t()]} | {:ok, paginated_result()} | {:error, term()}
  def get_events(filters \\ []) do
    GenServer.call(__MODULE__, {:get_events, filters})
  end

  @doc """
  Get a single event by ID.
  """
  @spec get_event(String.t()) :: {:ok, Event.t()} | {:error, :not_found}
  def get_event(event_id) do
    GenServer.call(__MODULE__, {:get_event, event_id})
  end

  @doc """
  Get the complete timeline for an agent.

  Returns events in chronological order with computed score deltas.
  """
  @spec get_agent_timeline(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_agent_timeline(agent_id, opts \\ []) do
    GenServer.call(__MODULE__, {:get_agent_timeline, agent_id, opts})
  end

  @doc """
  Get trust score progression for an agent.

  Shows how the trust score changed over time.
  """
  @spec get_trust_progression(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_trust_progression(agent_id, opts \\ []) do
    GenServer.call(__MODULE__, {:get_trust_progression, agent_id, opts})
  end

  @doc """
  Get tier change history for an agent.
  """
  @spec get_tier_history(String.t()) :: {:ok, [map()]} | {:error, term()}
  def get_tier_history(agent_id) do
    GenServer.call(__MODULE__, {:get_tier_history, agent_id})
  end

  @doc """
  Get aggregate statistics for an agent.
  """
  @spec get_agent_stats(String.t()) :: {:ok, map()} | {:error, term()}
  def get_agent_stats(agent_id) do
    GenServer.call(__MODULE__, {:get_agent_stats, agent_id})
  end

  @doc """
  Get system-wide trust statistics.
  """
  @spec get_system_stats() :: {:ok, map()} | {:error, term()}
  def get_system_stats do
    GenServer.call(__MODULE__, :get_system_stats)
  end

  @doc """
  Get recent negative events across all agents (for monitoring).
  """
  @spec get_recent_negative_events(keyword()) :: {:ok, [Event.t()]} | {:error, term()}
  def get_recent_negative_events(opts \\ []) do
    GenServer.call(__MODULE__, {:get_recent_negative_events, opts})
  end

  @doc """
  Get store statistics.
  """
  @spec get_store_stats() :: map()
  def get_store_stats do
    GenServer.call(__MODULE__, :get_store_stats)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    # Create ETS tables
    events_table =
      :ets.new(@table_name, [
        :set,
        :protected,
        :named_table,
        {:read_concurrency, true}
      ])

    index_table =
      :ets.new(@index_table, [
        :bag,
        :protected,
        :named_table,
        {:read_concurrency, true}
      ])

    event_log = opts[:event_log]

    state = %__MODULE__{
      events_table: events_table,
      index_table: index_table,
      event_log: event_log,
      stats: %{
        total_events: 0,
        events_by_type: %{},
        events_by_agent: %{},
        cache_hits: 0,
        cache_misses: 0
      }
    }

    Logger.info("Trust.EventStore started")

    {:ok, state}
  end

  @impl true
  def handle_call({:record_event, event}, _from, state) do
    :ok = record_event_impl(event, state)
    new_stats = update_stats(state.stats, event)
    {:reply, :ok, %{state | stats: new_stats}}
  end

  @impl true
  def handle_call({:record_events, events}, _from, state) do
    Enum.each(events, &record_event_impl(&1, state))
    new_stats = Enum.reduce(events, state.stats, &update_stats(&2, &1))
    {:reply, :ok, %{state | stats: new_stats}}
  end

  @impl true
  def handle_call({:get_events, filters}, _from, state) do
    result = get_events_impl(filters, state)
    {:reply, result, state}
  end

  @impl true
  # credo:disable-for-next-line Credo.Check.Design.DuplicatedCode
  def handle_call({:get_event, event_id}, _from, state) do
    result = get_event_impl(event_id, state)

    new_stats =
      case result do
        {:ok, _} -> %{state.stats | cache_hits: state.stats.cache_hits + 1}
        {:error, _} -> %{state.stats | cache_misses: state.stats.cache_misses + 1}
      end

    {:reply, result, %{state | stats: new_stats}}
  end

  @impl true
  def handle_call({:get_agent_timeline, agent_id, opts}, _from, state) do
    result = get_agent_timeline_impl(agent_id, opts, state)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_trust_progression, agent_id, opts}, _from, state) do
    result = get_trust_progression_impl(agent_id, opts, state)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_tier_history, agent_id}, _from, state) do
    result = get_tier_history_impl(agent_id, state)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_agent_stats, agent_id}, _from, state) do
    result = get_agent_stats_impl(agent_id, state)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_system_stats, _from, state) do
    result = get_system_stats_impl(state)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_recent_negative_events, opts}, _from, state) do
    result = get_recent_negative_events_impl(opts, state)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_store_stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        cache_size: :ets.info(state.events_table, :size),
        memory_bytes: :ets.info(state.events_table, :memory) * :erlang.system_info(:wordsize)
      })

    {:reply, stats, state}
  end

  # Private Implementation

  defp record_event_impl(%Event{} = event, state) do
    # Persist to unified EventLog (durable write path)
    persist_to_event_log(event, state)
    # Cache in domain ETS (read model)
    cache_event(event, state)
    # Emit signal (notification)
    emit_trust_signal(event)
    :ok
  end

  defp persist_to_event_log(_event, %{event_log: nil}), do: :ok

  defp persist_to_event_log(%Event{} = event, %{event_log: event_log}) do
    persistence_event = EventConverter.to_persistence_event(event)
    stream_id = EventConverter.stream_id(event)

    case PersistenceETS.append(stream_id, persistence_event, name: event_log) do
      {:ok, _persisted} -> :ok
      {:error, reason} ->
        Logger.warning("Trust.EventStore: failed to persist to EventLog: #{inspect(reason)}")
        :ok
    end
  end

  defp emit_trust_signal(%Event{} = event) do
    Arbor.Signals.emit(
      :trust,
      event.event_type,
      Event.to_map(event),
      source: "arbor.trust"
    )
  rescue
    _ -> :ok
  end

  defp cache_event(%Event{} = event, state) do
    # Store event by ID
    :ets.insert(state.events_table, {event.id, event})

    # Index by agent_id
    :ets.insert(state.index_table, {{:agent, event.agent_id}, event.id})

    # Index by event_type
    :ets.insert(state.index_table, {{:type, event.event_type}, event.id})

    # Index by timestamp (for range queries)
    ts_key = DateTime.to_unix(event.timestamp, :millisecond)
    :ets.insert(state.index_table, {{:time, ts_key}, event.id})

    # Prune cache if too large
    prune_cache_if_needed(state)
  end

  defp prune_cache_if_needed(state) do
    size = :ets.info(state.events_table, :size)

    if size > @max_cached_events do
      # Remove oldest 10% of events from cache
      to_remove = div(size, 10)

      state.events_table
      |> :ets.tab2list()
      |> Enum.sort_by(fn {_id, event} -> event.timestamp end)
      |> Enum.take(to_remove)
      |> Enum.each(fn {id, event} ->
        :ets.delete(state.events_table, id)
        :ets.delete_object(state.index_table, {{:agent, event.agent_id}, id})
        :ets.delete_object(state.index_table, {{:type, event.event_type}, id})
        ts_key = DateTime.to_unix(event.timestamp, :millisecond)
        :ets.delete_object(state.index_table, {{:time, ts_key}, id})
      end)
    end
  end

  # credo:disable-for-next-line Credo.Check.Design.DuplicatedCode
  defp get_event_impl(event_id, state) do
    case :ets.lookup(state.events_table, event_id) do
      [{^event_id, event}] ->
        {:ok, event}

      [] ->
        {:error, :not_found}
    end
  end

  defp get_events_impl(filters, state) do
    use_cursor = Keyword.has_key?(filters, :cursor)

    # Query from ETS cache using indexes when available
    events =
      cond do
        filters[:agent_id] ->
          get_from_cache_by_index({:agent, filters[:agent_id]}, state) || []

        filters[:event_type] && Enum.count(filters) == 1 ->
          get_from_cache_by_index({:type, filters[:event_type]}, state) || []

        true ->
          # Full scan of ETS table
          state.events_table
          |> :ets.tab2list()
          |> Enum.map(fn {_id, event} -> event end)
      end

    filtered_events = apply_filters_and_sort(events, filters)

    if use_cursor do
      build_paginated_result(filtered_events, filters)
    else
      {:ok, filtered_events}
    end
  end

  # credo:disable-for-next-line Credo.Check.Design.DuplicatedCode
  defp get_from_cache_by_index(index_key, state) do
    event_ids =
      state.index_table
      |> :ets.lookup(index_key)
      |> Enum.map(fn {_, id} -> id end)

    events =
      event_ids
      |> Enum.map(fn id ->
        case :ets.lookup(state.events_table, id) do
          [{^id, event}] -> event
          [] -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    if length(events) == length(event_ids) do
      events
    else
      nil
    end
  end

  defp apply_filters_and_sort(events, filters) do
    order = filters[:order] || :desc
    use_cursor = Keyword.has_key?(filters, :cursor)

    # When using cursor-based pagination, fetch limit + 1 to determine has_more
    effective_limit =
      if use_cursor && filters[:limit] do
        filters[:limit] + 1
      else
        filters[:limit]
      end

    events
    |> maybe_filter(:agent_id, filters[:agent_id])
    |> maybe_filter(:event_type, filters[:event_type])
    |> maybe_filter_time(:start_time, filters[:start_time])
    |> maybe_filter_time(:end_time, filters[:end_time])
    |> sort_events(order)
    |> maybe_filter_by_cursor(filters[:cursor], order)
    |> maybe_limit(effective_limit)
  end

  defp maybe_filter(events, _field, nil), do: events

  defp maybe_filter(events, field, value) do
    Enum.filter(events, &(Map.get(&1, field) == value))
  end

  defp maybe_filter_time(events, :start_time, nil), do: events

  defp maybe_filter_time(events, :start_time, start_time) do
    Enum.filter(events, &(DateTime.compare(&1.timestamp, start_time) != :lt))
  end

  defp maybe_filter_time(events, :end_time, nil), do: events

  defp maybe_filter_time(events, :end_time, end_time) do
    Enum.filter(events, &(DateTime.compare(&1.timestamp, end_time) != :gt))
  end

  defp sort_events(events, :asc) do
    # Sort by timestamp (milliseconds), then by ID as tiebreaker for same-timestamp events
    # Use milliseconds for consistent comparison with cursor-based pagination
    Enum.sort(events, fn a, b ->
      a_ts = DateTime.to_unix(a.timestamp, :millisecond)
      b_ts = DateTime.to_unix(b.timestamp, :millisecond)

      cond do
        a_ts < b_ts -> true
        a_ts > b_ts -> false
        true -> a.id < b.id
      end
    end)
  end

  defp sort_events(events, :desc) do
    # Sort by timestamp descending (milliseconds), then by ID descending as tiebreaker
    Enum.sort(events, fn a, b ->
      a_ts = DateTime.to_unix(a.timestamp, :millisecond)
      b_ts = DateTime.to_unix(b.timestamp, :millisecond)

      cond do
        a_ts > b_ts -> true
        a_ts < b_ts -> false
        true -> a.id > b.id
      end
    end)
  end

  defp maybe_filter_by_cursor(events, cursor, order) do
    Cursor.filter_records(events, cursor, order,
      timestamp_fn: & &1.timestamp,
      id_fn: & &1.id
    )
  end

  defp maybe_limit(events, nil), do: events
  defp maybe_limit(events, limit), do: Enum.take(events, limit)

  # Build paginated result with cursor
  # credo:disable-for-next-line Credo.Check.Design.DuplicatedCode
  defp build_paginated_result(events, filters) do
    limit = filters[:limit]

    {result_events, has_more} =
      if limit && length(events) > limit do
        {Enum.take(events, limit), true}
      else
        {events, false}
      end

    next_cursor =
      case List.last(result_events) do
        nil -> nil
        last -> generate_cursor(last)
      end

    {:ok, %{events: result_events, next_cursor: next_cursor, has_more: has_more}}
  end

  # Generate a cursor from an Event (timestamp_ms:event_id format)
  defp generate_cursor(%Event{timestamp: timestamp, id: id})
       when not is_nil(timestamp) and not is_nil(id) do
    Cursor.generate(timestamp, id)
  end

  defp generate_cursor(_), do: nil

  defp get_agent_timeline_impl(agent_id, opts, state) do
    limit = Keyword.get(opts, :limit, 100)
    {:ok, events} = get_events_impl([agent_id: agent_id, order: :asc, limit: limit], state)
    {:ok, build_timeline(agent_id, events)}
  end

  defp build_timeline(agent_id, events) do
    events_with_context =
      events
      |> Enum.with_index()
      |> Enum.map(fn {event, idx} ->
        next_event = Enum.at(events, idx + 1)

        time_to_next_ms =
          if next_event do
            DateTime.diff(next_event.timestamp, event.timestamp, :millisecond)
          else
            nil
          end

        %{
          id: event.id,
          event_type: event.event_type,
          timestamp: event.timestamp,
          previous_score: event.previous_score,
          new_score: event.new_score,
          delta: event.delta,
          previous_tier: event.previous_tier,
          new_tier: event.new_tier,
          reason: event.reason,
          metadata: event.metadata,
          time_to_next_ms: time_to_next_ms
        }
      end)

    total_duration_ms =
      case {List.first(events), List.last(events)} do
        {nil, _} -> 0
        {_, nil} -> 0
        {first, last} -> DateTime.diff(last.timestamp, first.timestamp, :millisecond)
      end

    %{
      agent_id: agent_id,
      events: events_with_context,
      event_count: length(events),
      total_duration_ms: total_duration_ms,
      first_event_at: List.first(events) && List.first(events).timestamp,
      last_event_at: List.last(events) && List.last(events).timestamp
    }
  end

  defp get_trust_progression_impl(agent_id, opts, state) do
    limit = Keyword.get(opts, :limit, 100)
    {:ok, events} = get_events_impl([agent_id: agent_id, order: :asc, limit: limit], state)

    # Extract score changes
    score_changes =
      events
      |> Enum.filter(&(&1.new_score != nil))
      |> Enum.map(fn event ->
        %{
          timestamp: event.timestamp,
          score: event.new_score,
          delta: event.delta,
          event_type: event.event_type
        }
      end)

    # Calculate statistics
    scores = Enum.map(score_changes, & &1.score)

    progression = %{
      agent_id: agent_id,
      score_history: score_changes,
      current_score: List.last(scores),
      min_score: if(Enum.empty?(scores), do: nil, else: Enum.min(scores)),
      max_score: if(Enum.empty?(scores), do: nil, else: Enum.max(scores)),
      total_positive_delta:
        events
        |> Enum.filter(&(&1.delta && &1.delta > 0))
        |> Enum.map(& &1.delta)
        |> Enum.sum(),
      total_negative_delta:
        events
        |> Enum.filter(&(&1.delta && &1.delta < 0))
        |> Enum.map(& &1.delta)
        |> Enum.sum(),
      data_points: length(score_changes)
    }

    {:ok, progression}
  end

  defp get_tier_history_impl(agent_id, state) do
    {:ok, events} =
      get_events_impl([agent_id: agent_id, event_type: :tier_changed, order: :asc], state)

    tier_changes =
      Enum.map(events, fn event ->
        %{
          timestamp: event.timestamp,
          from_tier: event.previous_tier,
          to_tier: event.new_tier,
          from_score: event.previous_score,
          to_score: event.new_score,
          direction: tier_direction(event.previous_tier, event.new_tier)
        }
      end)

    {:ok, tier_changes}
  end

  defp tier_direction(from, to) do
    tier_order = [:untrusted, :probationary, :trusted, :veteran, :autonomous]
    from_idx = Enum.find_index(tier_order, &(&1 == from)) || 0
    to_idx = Enum.find_index(tier_order, &(&1 == to)) || 0

    cond do
      to_idx > from_idx -> :promotion
      to_idx < from_idx -> :demotion
      true -> :unchanged
    end
  end

  defp get_agent_stats_impl(agent_id, state) do
    {:ok, events} = get_events_impl([agent_id: agent_id], state)
    {:ok, calculate_agent_stats(agent_id, events)}
  end

  defp calculate_agent_stats(agent_id, events) do
    by_type = Enum.group_by(events, & &1.event_type)

    success_count = length(by_type[:action_success] || [])
    failure_count = length(by_type[:action_failure] || [])
    total_actions = success_count + failure_count

    test_passed = length(by_type[:test_passed] || [])
    test_failed = length(by_type[:test_failed] || [])
    total_tests = test_passed + test_failed

    negative_events =
      Enum.count(events, fn e ->
        e.event_type in [:action_failure, :test_failed, :rollback_executed, :security_violation]
      end)

    %{
      agent_id: agent_id,
      total_events: length(events),
      events_by_type: Map.new(by_type, fn {k, v} -> {k, length(v)} end),
      action_success_rate: if(total_actions > 0, do: success_count / total_actions, else: nil),
      test_pass_rate: if(total_tests > 0, do: test_passed / total_tests, else: nil),
      security_violations: length(by_type[:security_violation] || []),
      rollbacks: length(by_type[:rollback_executed] || []),
      tier_changes: length(by_type[:tier_changed] || []),
      freezes: length(by_type[:trust_frozen] || []),
      negative_event_count: negative_events,
      first_event_at:
        List.last(Enum.sort_by(events, & &1.timestamp, DateTime)) &&
          List.last(Enum.sort_by(events, & &1.timestamp, DateTime)).timestamp,
      last_event_at:
        List.first(Enum.sort_by(events, & &1.timestamp, {:desc, DateTime})) &&
          List.first(Enum.sort_by(events, & &1.timestamp, {:desc, DateTime})).timestamp
    }
  end

  defp get_system_stats_impl(state) do
    # Get all unique agents from index
    agents =
      state.index_table
      |> :ets.match({{:agent, :"$1"}, :_})
      |> Enum.map(&hd/1)
      |> Enum.uniq()

    # Get event type distribution
    type_counts =
      state.stats.events_by_type

    stats = %{
      total_agents: length(agents),
      total_events: state.stats.total_events,
      events_by_type: type_counts,
      cache_size: :ets.info(state.events_table, :size),
      memory_bytes: :ets.info(state.events_table, :memory) * :erlang.system_info(:wordsize)
    }

    {:ok, stats}
  end

  defp get_recent_negative_events_impl(opts, state) do
    limit = Keyword.get(opts, :limit, 50)
    since_minutes = Keyword.get(opts, :since_minutes, 60)

    start_time = DateTime.add(DateTime.utc_now(), -since_minutes * 60, :second)

    negative_types = [
      :action_failure,
      :test_failed,
      :rollback_executed,
      :security_violation,
      :trust_frozen,
      :trust_decayed
    ]

    # Query each negative type and combine
    events =
      negative_types
      |> Enum.flat_map(fn type ->
        {:ok, events} = get_events_impl([event_type: type, start_time: start_time], state)
        events
      end)
      |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
      |> Enum.take(limit)

    {:ok, events}
  end

  defp update_stats(stats, %Event{} = event) do
    events_by_type =
      Map.update(stats.events_by_type, event.event_type, 1, &(&1 + 1))

    events_by_agent =
      Map.update(stats.events_by_agent, event.agent_id, 1, &(&1 + 1))

    %{
      stats
      | total_events: stats.total_events + 1,
        events_by_type: events_by_type,
        events_by_agent: events_by_agent
    }
  end

end
