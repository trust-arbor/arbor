defmodule Arbor.Persistence.EventLog.ETS do
  @moduledoc """
  ETS-backed implementation of the EventLog behaviour.

  Uses two ETS tables:
  - Stream table (`:ordered_set`): keyed by `{stream_id, event_number}`,
    value is the `global_position` integer pointer (NOT the event itself)
  - Global table (`:ordered_set`): keyed by `global_position`, value is the
    full `%Event{}` struct

  Per-stream reads walk the stream table to collect positions, then look
  each event up in the global table. This costs one extra ETS lookup per
  event read but cuts the in-memory footprint roughly in half — at scale
  the duplicate full-event storage in both indexes dominated total RAM
  (see `.arbor/roadmap/0-inbox/historian-startup-replay-cost.md`).

  Supports subscriber notifications via pid monitoring.

      children = [
        {Arbor.Persistence.EventLog.ETS, name: :my_event_log}
      ]
  """

  use GenServer

  require Logger

  @behaviour Arbor.Persistence.EventLog

  alias Arbor.Contracts.Persistence.AppendOperation
  alias Arbor.Persistence.{Event, EventLog}

  @default_max_events 1_000_000
  @default_max_read 10_000
  @max_identity_replay_events 1_000
  @warning_threshold 0.8

  # Retention: events older than max_age_ms get trimmed by a periodic
  # sweep. 24h is the initial choice (aggressive — we want to surface
  # any fallthrough-path bugs early; tune up if cache miss rate proves
  # too high). Disable per-instance by passing `:max_age_ms => :infinity`.
  @default_max_age_ms 24 * 60 * 60 * 1_000
  # 10 minutes between sweeps. Each sweep walks from the front of the
  # global table and stops at the first event still within the window,
  # so cost is proportional to "events that aged out since last sweep,"
  # not total event count. Disable with `:trim_interval_ms => :disabled`.
  @default_trim_interval_ms 10 * 60 * 1_000

  # --- Client API (EventLog behaviour) ---

  @impl Arbor.Persistence.EventLog
  def append(stream_id, events, opts) do
    EventLog.with_operation_deadline(opts, fn normalized_opts, deadline_mono ->
      with {:ok, events, preconditions, operation, ^deadline_mono} <-
             EventLog.prepare_append(stream_id, events, normalized_opts),
           {:ok, name} <- fetch_name(normalized_opts) do
        safe_append_call(
          name,
          {:append, stream_id, events, preconditions, operation, deadline_mono},
          deadline_mono,
          operation
        )
      end
    end)
  end

  @impl Arbor.Persistence.EventLog
  def reconcile_append(operation, opts) do
    EventLog.with_operation_deadline(opts, fn normalized_opts, deadline_mono ->
      with {:ok, operation, normalized_opts, ^deadline_mono} <-
             EventLog.prepare_reconcile(operation, normalized_opts),
           {:ok, name} <- fetch_name(normalized_opts) do
        reconcile_from_server(name, operation, deadline_mono)
      end
    end)
  end

  @impl Arbor.Persistence.EventLog
  def read_stream(stream_id, opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, {:read_stream, stream_id, opts})
  end

  @impl Arbor.Persistence.EventLog
  def read_stream_head(stream_id, opts) do
    with {:ok, max_current_age_ms} <- EventLog.validate_head_read(stream_id, opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.call(name, {:read_stream_head, stream_id, max_current_age_ms})
    end
  end

  @impl Arbor.Persistence.EventLog
  def read_all(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, {:read_all, opts})
  end

  @impl Arbor.Persistence.EventLog
  def stream_exists?(stream_id, opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, {:stream_exists?, stream_id})
  end

  @impl Arbor.Persistence.EventLog
  def stream_version(stream_id, opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, {:stream_version, stream_id})
  end

  @impl Arbor.Persistence.EventLog
  def subscribe(stream_id_or_all, pid, opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, {:subscribe, stream_id_or_all, pid})
  end

  @impl Arbor.Persistence.EventLog
  def list_streams(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, :list_streams)
  end

  @impl Arbor.Persistence.EventLog
  def stream_count(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, :stream_count)
  end

  @impl Arbor.Persistence.EventLog
  def event_count(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, :event_count)
  end

  @impl Arbor.Persistence.EventLog
  def read_agent_events(agent_id, opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, {:read_agent_events, agent_id, opts})
  end

  @doc """
  Return the lowest `event_number` currently held in ETS for `stream_id`,
  or `nil` if the stream has no events in cache.

  Used by `Arbor.Persistence` to decide whether a requested read range
  is fully covered by the ETS cache or whether the durable backend must
  be queried for events that have aged past retention.
  """
  @spec oldest_event_number(String.t(), keyword()) :: non_neg_integer() | nil
  def oldest_event_number(stream_id, opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, {:oldest_event_number, stream_id})
  end

  @doc """
  Align the in-memory `stream_versions` map and `global_position`
  counter with a snapshot from the durable backend, without inserting
  any events into the ETS tables.

  At boot time, the durable backend may hold many streams whose latest
  `event_number` and the system's latest `global_position` need to be
  reflected here so that subsequent `append/3` calls assign the correct
  next values (no collisions with already-persisted events). The actual
  events stay in the durable backend; reads for historical events go
  through fallthrough at the query layer.

  Idempotent: the `stream_versions` map is merged (max wins per stream)
  and `global_position` takes the max of current and incoming. Safe to
  call multiple times.
  """
  @spec rehydrate_metadata(
          %{
            stream_versions: %{String.t() => non_neg_integer()},
            global_position: non_neg_integer()
          },
          keyword()
        ) ::
          {:ok, :identity_history_complete | {:identity_history_unavailable, map()}}
          | {:error, :invalid_metadata_snapshot | :invalid_precondition | :backend_unavailable}
  def rehydrate_metadata(snapshot, opts) do
    with {:ok, name} <- fetch_name_from_public_opts(opts),
         {:ok, snapshot} <- validate_metadata_snapshot(snapshot) do
      safe_control_call(name, {:rehydrate_metadata, snapshot})
    end
  end

  @doc "Return whether the complete historical event-ID ledger is available."
  @spec identity_history_status(keyword()) ::
          {:ok, :identity_history_complete | {:identity_history_unavailable, map()}}
          | {:error, :invalid_precondition | :backend_unavailable}
  def identity_history_status(opts) do
    with {:ok, name} <- fetch_name_from_public_opts(opts) do
      safe_control_call(name, :identity_history_status)
    end
  end

  @doc """
  Replay one bounded page of positioned durable events into the identity ledger.

  Pass `complete: true` on the final page. Completeness is accepted only when
  the ledger contains one unique identity for every position through the
  rehydrated global position.
  """
  @spec replay_identity_history([Event.t()], keyword()) ::
          {:ok,
           %{
             accepted: non_neg_integer(),
             remaining: non_neg_integer(),
             status: :identity_history_complete | {:identity_history_unavailable, map()}
           }}
          | {:error,
             :invalid_identity_replay
             | :identity_replay_too_large
             | :invalid_precondition
             | :backend_unavailable}
  def replay_identity_history(events, opts) do
    with {:ok, name} <- fetch_name_from_public_opts(opts),
         {:ok, complete?} <- fetch_replay_complete(opts),
         {:ok, events} <- validate_identity_replay_page(events) do
      safe_control_call(name, {:replay_identity_history, events, complete?})
    end
  end

  # --- GenServer ---

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    max_events = Keyword.get(opts, :max_events, @default_max_events)

    # Safe: name is module atom from internal start_link opts, not user input
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    stream_table =
      :ets.new(:"#{name}_streams", [:ordered_set, :protected, read_concurrency: true])

    # Safe: name is module atom from internal start_link opts, not user input
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    global_table =
      :ets.new(:"#{name}_global", [:ordered_set, :protected, read_concurrency: true])

    # Safe: name is module atom from internal start_link opts, not user input
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    id_table = :ets.new(:"#{name}_ids", [:set, :protected, read_concurrency: true])

    # Safe: name is module atom from internal start_link opts, not user input
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    identity_position_table =
      :ets.new(:"#{name}_identity_positions", [
        :ordered_set,
        :protected,
        read_concurrency: true
      ])

    # Safe: name is module atom from internal start_link opts, not user input
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    identity_stream_position_table =
      :ets.new(:"#{name}_identity_stream_positions", [
        :set,
        :protected,
        read_concurrency: true
      ])

    max_age_ms = Keyword.get(opts, :max_age_ms, @default_max_age_ms)
    trim_interval_ms = Keyword.get(opts, :trim_interval_ms, @default_trim_interval_ms)
    append_candidate_hook = Keyword.get(opts, :append_candidate_hook)

    base_state = %{
      stream_table: stream_table,
      global_table: global_table,
      id_table: id_table,
      identity_position_table: identity_position_table,
      identity_stream_position_table: identity_stream_position_table,
      identity_history: :complete,
      identity_metadata_consistent: true,
      global_position: 0,
      max_events: max_events,
      warning_logged: false,
      stream_versions: %{},
      head_inserted_mono: %{},
      subscribers: %{},
      monitors: %{},
      max_age_ms: max_age_ms,
      trim_interval_ms: trim_interval_ms,
      append_candidate_hook: append_candidate_hook
    }

    # Attempt to restore from snapshot if configured
    snapshot_store = Keyword.get(opts, :snapshot_store)
    snapshot_store_opts = Keyword.get(opts, :snapshot_store_opts, [])
    snapshot_namespace = Keyword.get(opts, :snapshot_namespace, "eventlog_snapshots")

    state =
      maybe_restore_from_snapshot(
        base_state,
        snapshot_store,
        snapshot_store_opts,
        snapshot_namespace
      )

    schedule_trim(state)

    {:ok, state}
  end

  @impl GenServer
  def handle_call(
        {:append, stream_id, events, preconditions, operation, deadline_mono},
        _from,
        state
      ) do
    now = System.monotonic_time(:millisecond)

    {result, state} =
      if now >= deadline_mono do
        {{:error, :operation_timeout}, state}
      else
        case reconcile_operation(operation, events, state) do
          {:ok, {:committed, persisted}} ->
            {{:ok, persisted}, state}

          {:ok, :absent} ->
            append_absent_operation(
              stream_id,
              events,
              preconditions,
              operation,
              deadline_mono,
              now,
              state
            )

          {:error, reason} ->
            {{:error, reason}, state}
        end
      end

    {:reply, EventLog.stamp_completion(result), state}
  end

  def handle_call({:reconcile_append, operation, deadline_mono}, _from, state) do
    result =
      if System.monotonic_time(:millisecond) < deadline_mono,
        do: reconcile_operation(operation, state),
        else: {:error, :operation_timeout}

    {:reply, EventLog.stamp_completion(result), state}
  end

  def handle_call({:read_stream, stream_id, opts}, _from, state) do
    from_num = Keyword.get(opts, :from, 0)
    limit = Keyword.get(opts, :limit)
    direction = Keyword.get(opts, :direction, :forward)
    # :max_scan bounds how many stream events are walked into memory before
    # the limit is applied (DoS backstop — codex resource-exhaustion.historian
    # -taint-query-full-scan). nil = unbounded (existing behavior). Intended for
    # :forward reads.
    max_scan = Keyword.get(opts, :max_scan)

    events =
      do_read_stream(
        state.stream_table,
        state.global_table,
        stream_id,
        from_num,
        limit,
        direction,
        max_scan
      )

    {:reply, {:ok, events}, state}
  end

  def handle_call({:read_stream_head, stream_id, max_current_age_ms}, _from, state) do
    reply =
      case read_head_event(stream_id, state) do
        :empty ->
          {:ok, nil}

        :unavailable ->
          {:error, :head_unavailable}

        {:ok, event} ->
          if fresh_head?(
               stream_id,
               max_current_age_ms,
               System.monotonic_time(:millisecond),
               state
             ) do
            {:ok, event}
          else
            {:ok, nil}
          end
      end

    {:reply, reply, state}
  end

  def handle_call({:read_all, opts}, _from, state) do
    from_pos = Keyword.get(opts, :from, 0)
    limit = Keyword.get(opts, :limit, @default_max_read)

    events = do_read_all(state.global_table, from_pos, limit)
    {:reply, {:ok, events}, state}
  end

  def handle_call({:stream_exists?, stream_id}, _from, state) do
    exists = Map.has_key?(state.stream_versions, stream_id)
    {:reply, exists, state}
  end

  def handle_call({:stream_version, stream_id}, _from, state) do
    version = Map.get(state.stream_versions, stream_id, 0)
    {:reply, {:ok, version}, state}
  end

  def handle_call({:subscribe, stream_id_or_all, pid}, _from, state) do
    ref = Process.monitor(pid)
    sub_key = stream_id_or_all

    subscribers =
      Map.update(state.subscribers, sub_key, [{pid, ref}], &[{pid, ref} | &1])

    monitors = Map.put(state.monitors, ref, {sub_key, pid})

    {:reply, {:ok, ref}, %{state | subscribers: subscribers, monitors: monitors}}
  end

  def handle_call(:list_streams, _from, state) do
    {:reply, {:ok, Map.keys(state.stream_versions)}, state}
  end

  def handle_call(:stream_count, _from, state) do
    {:reply, {:ok, map_size(state.stream_versions)}, state}
  end

  def handle_call(:event_count, _from, state) do
    {:reply, {:ok, state.global_position}, state}
  end

  def handle_call(:export_state, _from, state) do
    events = do_read_all(state.global_table, 0, nil)
    serialized = Enum.map(events, &serialize_event/1)
    identity_tombstones = export_identity_tombstones(state.id_table)

    snapshot = %{
      snapshot_version: 2,
      global_position: state.global_position,
      stream_versions: state.stream_versions,
      max_events: state.max_events,
      events: serialized,
      identity_tombstones: identity_tombstones,
      identity_history: serialize_identity_history(state)
    }

    {:reply, {:ok, snapshot}, state}
  end

  def handle_call({:rehydrate_metadata, snapshot}, _from, state) do
    rehydrated_stream_ids =
      Enum.reduce(snapshot.stream_versions, [], fn {stream_id, incoming_version}, acc ->
        case Map.fetch(state.stream_versions, stream_id) do
          :error -> [stream_id | acc]
          {:ok, current_version} when incoming_version > current_version -> [stream_id | acc]
          {:ok, _current_version} -> acc
        end
      end)

    merged_stream_versions =
      Map.merge(state.stream_versions, snapshot.stream_versions, fn _k, current, incoming ->
        max(current, incoming)
      end)

    new_global_position = max(state.global_position, snapshot.global_position)

    head_inserted_mono =
      Enum.reduce(rehydrated_stream_ids, state.head_inserted_mono, fn stream_id, freshness ->
        Map.put(freshness, stream_id, :unknown)
      end)

    candidate = %{
      state
      | stream_versions: merged_stream_versions,
        global_position: new_global_position,
        head_inserted_mono: head_inserted_mono,
        identity_metadata_consistent:
          metadata_sequence_consistent?(merged_stream_versions, new_global_position)
    }

    candidate =
      if complete_identity_ledger?(candidate) do
        %{candidate | identity_history: :complete}
      else
        %{candidate | identity_history: {:unavailable, incomplete_metadata_reason(candidate)}}
      end

    {:reply, {:ok, format_identity_history(candidate)}, candidate}
  end

  def handle_call(:identity_history_status, _from, state) do
    {:reply, {:ok, format_identity_history(state)}, state}
  end

  def handle_call({:replay_identity_history, events, complete?}, _from, state) do
    case prepare_identity_replay(events, state) do
      {:ok, entries} ->
        Enum.each(entries, fn {event_id, identity, global_position, stream_position} ->
          :ets.insert(state.id_table, {event_id, identity})
          :ets.insert(state.identity_position_table, {global_position, event_id})
          :ets.insert(state.identity_stream_position_table, {stream_position, event_id})
        end)

        candidate =
          if complete? and complete_identity_ledger?(state),
            do: %{state | identity_history: :complete},
            else: %{state | identity_history: {:unavailable, incomplete_metadata_reason(state)}}

        remaining = identity_history_remaining(candidate)

        {:reply,
         {:ok,
          %{
            accepted: length(entries),
            remaining: remaining,
            status: format_identity_history(candidate)
          }}, candidate}

      {:error, :invalid_identity_replay} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:oldest_event_number, stream_id}, _from, state) do
    # The stream table is keyed by `{stream_id, event_number}` in an
    # `:ordered_set`. `:ets.next/2` from `{stream_id, 0}` returns the
    # next key in tuple-sort order — which is the lowest event_number
    # for this stream, OR the first key of the next stream if this
    # stream is fully evicted.
    result =
      case :ets.next(state.stream_table, {stream_id, 0}) do
        {^stream_id, n} -> n
        _ -> nil
      end

    {:reply, {:ok, result}, state}
  end

  def handle_call({:read_agent_events, agent_id, opts}, _from, state) do
    limit = Keyword.get(opts, :limit)
    type = Keyword.get(opts, :type)

    events =
      do_read_all(state.global_table, 0, nil)
      |> Enum.filter(fn event ->
        event.agent_id == agent_id and
          (type == nil or event.type == type)
      end)

    events = if limit, do: Enum.take(events, limit), else: events
    {:reply, {:ok, events}, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, monitors} ->
        {:noreply, %{state | monitors: monitors}}

      {{sub_key, pid}, monitors} ->
        subscribers = remove_subscriber(state.subscribers, sub_key, pid, ref)
        {:noreply, %{state | subscribers: subscribers, monitors: monitors}}
    end
  end

  def handle_info(:trim_old_events, state) do
    state = do_trim(state)
    schedule_trim(state)
    {:noreply, state}
  end

  # --- Private ---

  # ----- Retention sweep -----

  defp schedule_trim(%{trim_interval_ms: :disabled}), do: :ok

  defp schedule_trim(%{trim_interval_ms: ms}) when is_integer(ms) and ms > 0 do
    Process.send_after(self(), :trim_old_events, ms)
    :ok
  end

  defp schedule_trim(_), do: :ok

  defp do_trim(%{max_age_ms: :infinity} = state), do: state

  defp do_trim(%{max_age_ms: max_age_ms} = state) when is_integer(max_age_ms) do
    cutoff = DateTime.add(DateTime.utc_now(), -max_age_ms, :millisecond)
    trim_from_front(state, cutoff, 0)
  end

  defp do_trim(state), do: state

  # Walk the global table from the lowest global_position upward, deleting
  # entries whose timestamp predates cutoff. Stop on the first entry that's
  # still within the window — the table is ordered by global_position, but
  # timestamps within bounded clock skew are monotonic enough that this
  # gives a correct-to-the-second sweep for any practical workload.
  #
  # An event with `nil` timestamp is treated as "keep" (stops the sweep)
  # — we don't want to silently lose events with malformed metadata.
  defp trim_from_front(state, cutoff, trimmed) do
    case :ets.first(state.global_table) do
      :"$end_of_table" ->
        log_trim(trimmed)
        state

      gpos ->
        case :ets.lookup(state.global_table, gpos) do
          [{^gpos, event}] ->
            cond do
              is_nil(event.timestamp) ->
                log_trim(trimmed)
                state

              DateTime.compare(event.timestamp, cutoff) == :lt ->
                :ets.delete(state.global_table, gpos)
                :ets.delete(state.stream_table, {event.stream_id, event.event_number})

                # Preserve the bounded ID/fingerprint entry after payload retention.
                # Without this tombstone, retrying a trimmed append could create a
                # second event with the same durable operation identity.
                trim_from_front(state, cutoff, trimmed + 1)

              true ->
                log_trim(trimmed)
                state
            end

          [] ->
            log_trim(trimmed)
            state
        end
    end
  end

  defp log_trim(0), do: :ok

  defp log_trim(n) do
    Logger.debug("EventLog.ETS: trimmed #{n} events past retention window")
    :ok
  end

  # ----- Subscriber bookkeeping -----

  defp remove_subscriber(subscribers, sub_key, pid, ref) do
    Map.update(subscribers, sub_key, [], fn subs ->
      Enum.reject(subs, fn {p, r} -> p == pid and r == ref end)
    end)
  end

  defp decrement_limit(nil), do: nil
  defp decrement_limit(n), do: n - 1

  defp build_append(stream_id, events, operation, state) do
    current_version = Map.get(state.stream_versions, stream_id, 0)

    {persisted, final_version, final_global} =
      events
      |> Enum.reduce({[], current_version, state.global_position}, fn %Event{} = event,
                                                                      {acc, ver, gpos} ->
        new_ver = ver + 1
        new_gpos = gpos + 1

        persisted_event = %Event{
          event
          | event_number: new_ver,
            global_position: new_gpos,
            stream_id: stream_id
        }

        {[persisted_event | acc], new_ver, new_gpos}
      end)

    persisted = Enum.reverse(persisted)

    stream_entries =
      Enum.map(persisted, &{{stream_id, &1.event_number}, &1.global_position})

    global_entries = Enum.map(persisted, &{&1.global_position, &1})

    id_entries =
      Enum.map(persisted, fn event ->
        {event.id,
         {
           Map.fetch!(operation.fingerprints, event.id),
           event.stream_id,
           event.event_number,
           event.global_position
         }}
      end)

    candidate = %{
      state
      | global_position: final_global,
        stream_versions: Map.put(state.stream_versions, stream_id, final_version)
    }

    {persisted, stream_entries, global_entries, id_entries, candidate}
  end

  defp append_absent_operation(
         stream_id,
         events,
         preconditions,
         operation,
         deadline_mono,
         now,
         state
       ) do
    current_version = Map.get(state.stream_versions, stream_id, 0)

    with :ok <- check_preconditions(stream_id, preconditions, now, state),
         :ok <- check_capacity(events, state),
         :ok <-
           EventLog.ensure_position_capacity(
             current_version,
             state.global_position,
             length(events)
           ),
         {:ok, _remaining} <- EventLog.remaining_timeout(deadline_mono) do
      {persisted, stream_entries, global_entries, id_entries, candidate} =
        build_append(stream_id, events, operation, state)

      run_candidate_hook(state)

      if System.monotonic_time(:millisecond) >= deadline_mono do
        {{:error, :operation_timeout}, state}
      else
        :ets.insert(state.stream_table, stream_entries)
        :ets.insert(state.global_table, global_entries)
        :ets.insert(state.id_table, id_entries)

        identity_position_entries =
          Enum.map(id_entries, fn {event_id, {_fingerprint, _stream_id, _event_number, position}} ->
            {position, event_id}
          end)

        identity_stream_position_entries =
          Enum.map(id_entries, fn {event_id, {_fingerprint, stream_id, event_number, _position}} ->
            {{stream_id, event_number}, event_id}
          end)

        :ets.insert(state.identity_position_table, identity_position_entries)
        :ets.insert(state.identity_stream_position_table, identity_stream_position_entries)
        committed_mono = System.monotonic_time(:millisecond)

        if committed_mono >= deadline_mono do
          rollback_append_entries(
            state,
            stream_entries,
            global_entries,
            id_entries,
            identity_position_entries,
            identity_stream_position_entries
          )

          {{:error, :operation_timeout}, state}
        else
          candidate = %{
            candidate
            | head_inserted_mono: Map.put(candidate.head_inserted_mono, stream_id, committed_mono)
          }

          notify_subscribers(stream_id, persisted, candidate)
          candidate = maybe_warn_event_capacity(candidate)
          {{:ok, persisted}, candidate}
        end
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp reconcile_operation(%AppendOperation{} = operation, state) do
    reconcile_operation(operation, nil, state)
  end

  defp reconcile_operation(%AppendOperation{} = operation, submitted_events, state) do
    submitted_by_id =
      if is_list(submitted_events), do: Map.new(submitted_events, &{&1.id, &1}), else: %{}

    {events, conflict?, partial?} =
      Enum.reduce(operation.event_ids, {[], false, false}, fn event_id,
                                                              {events, conflict?, partial?} ->
        case :ets.lookup(state.id_table, event_id) do
          [{^event_id, identity}] ->
            submitted_event = Map.get(submitted_by_id, event_id)

            case reconcile_identity_entry(
                   identity,
                   operation,
                   event_id,
                   submitted_event,
                   state
                 ) do
              {:event, event} -> {[event | events], conflict?, partial?}
              :partial -> {events, conflict?, true}
              :conflict -> {events, true, partial?}
            end

          [] ->
            {events, conflict?, partial?}
        end
      end)

    cond do
      conflict? -> {:error, :event_identity_conflict}
      partial? -> EventLog.indeterminate(operation)
      events == [] and identity_history_unavailable?(state) -> EventLog.indeterminate(operation)
      true -> EventLog.reconcile_events(operation, Enum.reverse(events))
    end
  end

  defp safe_append_call(name, request, deadline_mono, operation) do
    with {:ok, timeout} <- EventLog.remaining_timeout(deadline_mono) do
      name
      |> GenServer.call(request, timeout)
      |> EventLog.accept_completion(operation, deadline_mono)
    else
      {:error, :operation_timeout} -> EventLog.indeterminate(operation)
    end
  rescue
    _error -> EventLog.indeterminate(operation)
  catch
    :exit, _reason -> EventLog.indeterminate(operation)
  end

  defp reconcile_from_server(name, operation, deadline_mono) do
    with {:ok, timeout} <- EventLog.remaining_timeout(deadline_mono) do
      name
      |> GenServer.call({:reconcile_append, operation, deadline_mono}, timeout)
      |> EventLog.accept_completion(operation, deadline_mono)
    else
      {:error, :operation_timeout} -> EventLog.indeterminate(operation)
    end
  catch
    :exit, _reason -> EventLog.indeterminate(operation)
  end

  defp fetch_name(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} when is_atom(name) and not is_nil(name) -> {:ok, name}
      _missing_or_invalid -> {:error, :invalid_precondition}
    end
  end

  defp fetch_name_from_public_opts(opts) do
    with {:ok, normalized_opts} <- EventLog.normalize_opts(opts),
         {:ok, name} <- fetch_name(normalized_opts) do
      {:ok, name}
    end
  end

  defp safe_control_call(name, request) do
    GenServer.call(name, request)
  rescue
    _error -> {:error, :backend_unavailable}
  catch
    :exit, _reason -> {:error, :backend_unavailable}
  end

  defp fetch_replay_complete(opts) do
    with {:ok, normalized_opts} <- EventLog.normalize_opts(opts) do
      case Keyword.get(normalized_opts, :complete, false) do
        complete? when is_boolean(complete?) -> {:ok, complete?}
        _invalid -> {:error, :invalid_precondition}
      end
    end
  end

  defp validate_metadata_snapshot(%{
         stream_versions: stream_versions,
         global_position: global_position
       })
       when is_map(stream_versions) and map_size(stream_versions) <= @default_max_events and
              is_integer(global_position) and global_position >= 0 and
              global_position <= 2_147_483_647 do
    valid? =
      Enum.all?(stream_versions, fn {stream_id, version} ->
        is_binary(stream_id) and byte_size(stream_id) > 0 and byte_size(stream_id) <= 255 and
          String.valid?(stream_id) and is_integer(version) and version >= 0 and
          version <= 2_147_483_647
      end)

    if valid?,
      do: {:ok, %{stream_versions: stream_versions, global_position: global_position}},
      else: {:error, :invalid_metadata_snapshot}
  end

  defp validate_metadata_snapshot(_invalid), do: {:error, :invalid_metadata_snapshot}

  defp validate_identity_replay_page(events) do
    validate_identity_replay_page(events, 0, [])
  end

  defp validate_identity_replay_page([], _count, acc), do: {:ok, Enum.reverse(acc)}

  defp validate_identity_replay_page(_remaining, @max_identity_replay_events, _acc),
    do: {:error, :identity_replay_too_large}

  defp validate_identity_replay_page([%Event{} = event | rest], count, acc),
    do: validate_identity_replay_page(rest, count + 1, [event | acc])

  defp validate_identity_replay_page(_improper_or_invalid, _count, _acc),
    do: {:error, :invalid_identity_replay}

  defp prepare_identity_replay(events, state) do
    events
    |> Enum.reduce_while(
      {:ok, [], MapSet.new(), MapSet.new(), MapSet.new()},
      fn event, {:ok, entries, page_ids, page_positions, page_stream_positions} ->
        case identity_replay_entry(
               event,
               state,
               page_ids,
               page_positions,
               page_stream_positions
             ) do
          {:ok, :existing, event_id, global_position, stream_position} ->
            {:cont,
             {:ok, entries, MapSet.put(page_ids, event_id),
              MapSet.put(page_positions, global_position),
              MapSet.put(page_stream_positions, stream_position)}}

          {:ok, identity, event_id, global_position, stream_position} ->
            {:cont,
             {:ok, [{event_id, identity, global_position, stream_position} | entries],
              MapSet.put(page_ids, event_id), MapSet.put(page_positions, global_position),
              MapSet.put(page_stream_positions, stream_position)}}

          {:error, :invalid_identity_replay} = error ->
            {:halt, error}
        end
      end
    )
    |> case do
      {:ok, entries, _ids, _positions, _stream_positions} -> {:ok, Enum.reverse(entries)}
      {:error, :invalid_identity_replay} = error -> error
    end
  end

  defp identity_replay_entry(
         %Event{} = event,
         state,
         page_ids,
         page_positions,
         page_stream_positions
       ) do
    fingerprint = EventLog.event_fingerprint(event.stream_id, event)
    stream_version = Map.get(state.stream_versions, event.stream_id, 0)

    valid? =
      is_binary(fingerprint) and is_integer(event.event_number) and event.event_number > 0 and
        event.event_number <= stream_version and is_integer(event.global_position) and
        event.global_position > 0 and event.global_position <= state.global_position and
        not MapSet.member?(page_ids, event.id) and
        not MapSet.member?(page_positions, event.global_position) and
        not MapSet.member?(page_stream_positions, {event.stream_id, event.event_number})

    identity =
      {fingerprint, event.stream_id, event.event_number, event.global_position}

    stream_position = {event.stream_id, event.event_number}

    if valid? do
      classify_replay_identity(
        event.id,
        identity,
        event.global_position,
        stream_position,
        state
      )
    else
      {:error, :invalid_identity_replay}
    end
  end

  defp classify_replay_identity(event_id, identity, global_position, stream_position, state) do
    id_entry = :ets.lookup(state.id_table, event_id)
    position_entry = :ets.lookup(state.identity_position_table, global_position)

    stream_position_entry =
      :ets.lookup(state.identity_stream_position_table, stream_position)

    case {id_entry, position_entry, stream_position_entry} do
      {[], [], []} ->
        {:ok, identity, event_id, global_position, stream_position}

      {
        [{^event_id, ^identity}],
        [{^global_position, ^event_id}],
        [{^stream_position, ^event_id}]
      } ->
        {:ok, :existing, event_id, global_position, stream_position}

      _conflict ->
        {:error, :invalid_identity_replay}
    end
  end

  defp complete_identity_ledger?(state) do
    state.identity_metadata_consistent and
      :ets.info(state.id_table, :size) == state.global_position and
      :ets.info(state.identity_position_table, :size) == state.global_position and
      :ets.info(state.identity_stream_position_table, :size) == state.global_position
  end

  defp incomplete_metadata_reason(%{identity_metadata_consistent: false}),
    do: :metadata_sequence_inconsistent

  defp incomplete_metadata_reason(%{identity_history: {:unavailable, reason}}), do: reason
  defp incomplete_metadata_reason(_state), do: :durable_metadata_only

  defp metadata_sequence_consistent?(stream_versions, global_position) do
    stream_versions
    |> Enum.reduce_while(0, fn {_stream_id, version}, total ->
      next_total = total + version

      if next_total <= global_position,
        do: {:cont, next_total},
        else: {:halt, :inconsistent}
    end)
    |> case do
      ^global_position -> true
      _different -> false
    end
  end

  defp identity_history_remaining(state) do
    max(state.global_position - :ets.info(state.id_table, :size), 0)
  end

  defp identity_history_unavailable?(%{identity_history: :complete}), do: false
  defp identity_history_unavailable?(_state), do: true

  defp format_identity_history(%{identity_history: :complete}),
    do: :identity_history_complete

  defp format_identity_history(%{identity_history: {:unavailable, reason}} = state) do
    {:identity_history_unavailable,
     %{
       reason: reason,
       expected_events: state.global_position,
       loaded_events: :ets.info(state.id_table, :size)
     }}
  end

  defp serialize_identity_history(%{identity_history: :complete}),
    do: %{"status" => "complete"}

  defp serialize_identity_history(%{identity_history: {:unavailable, reason}} = state) do
    %{
      "status" => "unavailable",
      "reason" => Atom.to_string(reason),
      "expected_events" => state.global_position,
      "loaded_events" => :ets.info(state.id_table, :size)
    }
  end

  defp rollback_append_entries(
         state,
         stream_entries,
         global_entries,
         id_entries,
         identity_position_entries,
         identity_stream_position_entries
       ) do
    Enum.each(stream_entries, &:ets.delete(state.stream_table, elem(&1, 0)))
    Enum.each(global_entries, &:ets.delete(state.global_table, elem(&1, 0)))
    Enum.each(id_entries, &:ets.delete(state.id_table, elem(&1, 0)))
    Enum.each(identity_position_entries, &:ets.delete(state.identity_position_table, elem(&1, 0)))

    Enum.each(
      identity_stream_position_entries,
      &:ets.delete(state.identity_stream_position_table, elem(&1, 0))
    )

    :ok
  end

  defp normalize_identity({fingerprint, stream_id, event_number, global_position})
       when is_binary(fingerprint) and is_binary(stream_id) and is_integer(event_number) and
              event_number > 0 and is_integer(global_position) and global_position > 0,
       do: {:ok, fingerprint, stream_id, event_number, global_position}

  defp normalize_identity({fingerprint, global_position})
       when is_binary(fingerprint) and is_integer(global_position) and global_position > 0,
       do: {:ok, fingerprint, nil, nil, global_position}

  defp normalize_identity(_identity), do: {:error, :invalid_identity}

  defp reconcile_identity_entry(identity, operation, event_id, submitted_event, state) do
    with {:ok, fingerprint, stream_id, event_number, global_position} <-
           normalize_identity(identity),
         true <-
           compatible_identity?(
             operation,
             event_id,
             fingerprint,
             stream_id,
             submitted_event
           ) do
      case :ets.lookup(state.global_table, global_position) do
        [{^global_position, %Event{} = event}] ->
          {:event, event}

        [] ->
          rebuild_tombstoned_event(
            submitted_event,
            stream_id,
            event_number,
            global_position
          )
      end
    else
      _invalid_or_conflicting -> :conflict
    end
  end

  defp rebuild_tombstoned_event(
         %Event{} = submitted_event,
         stream_id,
         event_number,
         global_position
       )
       when is_binary(stream_id) and is_integer(event_number) do
    {:event,
     %Event{
       submitted_event
       | stream_id: stream_id,
         event_number: event_number,
         global_position: global_position
     }}
  end

  defp rebuild_tombstoned_event(_submitted_event, _stream_id, _event_number, _global_position),
    do: :partial

  defp compatible_identity?(operation, event_id, fingerprint, stream_id, submitted_event) do
    stream_matches? = is_nil(stream_id) or stream_id == operation.stream_id
    expected = Map.get(operation.fingerprints, event_id)

    stream_matches? and
      (fingerprint == expected or
         (is_struct(submitted_event, Event) and
            EventLog.event_fingerprint_matches?(
              operation.stream_id,
              submitted_event,
              fingerprint
            )))
  end

  defp export_identity_tombstones(id_table) do
    id_table
    |> :ets.tab2list()
    |> Enum.map(fn {event_id, identity} ->
      case normalize_identity(identity) do
        {:ok, fingerprint, stream_id, event_number, global_position} ->
          %{
            "event_id" => event_id,
            "fingerprint" => fingerprint,
            "stream_id" => stream_id,
            "event_number" => event_number,
            "global_position" => global_position
          }

        {:error, :invalid_identity} ->
          raise "invalid EventLog identity ledger entry for #{inspect(event_id)}"
      end
    end)
  end

  defp run_candidate_hook(%{append_candidate_hook: hook}) when is_function(hook, 0), do: hook.()
  defp run_candidate_hook(_state), do: :ok

  defp check_preconditions(stream_id, preconditions, now, state) do
    current_version = Map.get(state.stream_versions, stream_id, 0)

    cond do
      not is_nil(preconditions.expected_version) and
          preconditions.expected_version != current_version ->
        {:error, :version_conflict}

      not fresh_head?(stream_id, preconditions.max_current_age_ms, now, state) ->
        {:error, :deadline_exceeded}

      true ->
        :ok
    end
  end

  defp fresh_head?(_stream_id, nil, _now, _state), do: true

  defp fresh_head?(stream_id, max_age_ms, now, state) do
    case Map.get(state.head_inserted_mono, stream_id) do
      inserted when is_integer(inserted) -> now - inserted < max_age_ms
      _empty_or_unknown -> false
    end
  end

  defp check_capacity(events, state) do
    if state.global_position + length(events) > state.max_events,
      do: {:error, :event_log_full},
      else: :ok
  end

  defp read_head_event(stream_id, state) do
    version = Map.get(state.stream_versions, stream_id, 0)

    if version == 0 do
      :empty
    else
      with [{{^stream_id, ^version}, global_position}] <-
             :ets.lookup(state.stream_table, {stream_id, version}),
           [{^global_position, event}] <- :ets.lookup(state.global_table, global_position) do
        {:ok, event}
      else
        _ -> :unavailable
      end
    end
  end

  defp do_read_stream(
         stream_table,
         global_table,
         stream_id,
         from_num,
         limit,
         direction,
         max_scan
       ) do
    # Walk the stream table to collect global_position pointers, then
    # dereference each one via the global table to get the full event.
    # See moduledoc for why stream table holds pointers, not events.
    events = collect_stream_events(stream_table, global_table, stream_id, from_num, [], max_scan)

    events =
      case direction do
        :forward -> events
        :backward -> Enum.reverse(events)
      end

    case limit do
      nil -> events
      n -> Enum.take(events, n)
    end
  end

  # remaining: nil = unbounded (default). 0 = scan ceiling reached → stop.
  defp collect_stream_events(_st, _gt, _sid, _from_num, acc, 0), do: Enum.reverse(acc)

  defp collect_stream_events(stream_table, global_table, stream_id, from_num, acc, remaining) do
    key = {stream_id, from_num}

    case :ets.lookup(stream_table, key) do
      [{^key, gpos}] ->
        case :ets.lookup(global_table, gpos) do
          [{^gpos, event}] ->
            collect_stream_events(
              stream_table,
              global_table,
              stream_id,
              from_num + 1,
              [event | acc],
              decrement_limit(remaining)
            )

          [] ->
            # Stream pointer dangling — global entry trimmed but stream
            # entry survived. Treat as end-of-stream for this read; the
            # retention sweep should remove both atomically, so a dangle
            # is a bug we want to surface eventually. For now: stop here.
            Enum.reverse(acc)
        end

      [] ->
        # Check if there's a next key in this stream (handles from_num=0 case)
        case :ets.next(stream_table, key) do
          {^stream_id, next_num} ->
            collect_stream_events(stream_table, global_table, stream_id, next_num, acc, remaining)

          _ ->
            Enum.reverse(acc)
        end
    end
  end

  defp do_read_all(table, from_pos, limit) do
    events = collect_global_events(table, from_pos, limit, [])
    Enum.reverse(events)
  end

  defp collect_global_events(_table, _pos, 0, acc), do: acc

  defp collect_global_events(table, pos, limit, acc) do
    case :ets.lookup(table, pos) do
      [{^pos, event}] ->
        new_limit = decrement_limit(limit)
        collect_global_events(table, pos + 1, new_limit, [event | acc])

      [] ->
        collect_from_next_position(table, pos, limit, acc)
    end
  end

  defp collect_from_next_position(table, pos, limit, acc) do
    case :ets.next(table, pos) do
      :"$end_of_table" ->
        acc

      next_pos when is_integer(next_pos) ->
        [{^next_pos, event}] = :ets.lookup(table, next_pos)
        new_limit = decrement_limit(limit)
        collect_global_events(table, next_pos + 1, new_limit, [event | acc])

      _ ->
        acc
    end
  end

  defp notify_subscribers(stream_id, events, state) do
    # Notify stream-specific subscribers
    stream_subs = Map.get(state.subscribers, stream_id, [])
    all_subs = Map.get(state.subscribers, :all, [])

    for event <- events do
      for {pid, _ref} <- stream_subs, do: send(pid, {:event, event})
      for {pid, _ref} <- all_subs, do: send(pid, {:event, event})
    end
  end

  defp maybe_warn_event_capacity(%{warning_logged: true} = state), do: state

  defp maybe_warn_event_capacity(%{global_position: pos, max_events: max} = state) do
    threshold = trunc(max * @warning_threshold)

    if pos >= threshold do
      Logger.warning("EventLog approaching capacity",
        event_count: pos,
        max_events: max,
        utilization: "#{round(pos / max * 100)}%"
      )

      %{state | warning_logged: true}
    else
      state
    end
  end

  # --- Snapshot Serialization ---

  defp serialize_event(%Event{} = event) do
    %{
      "id" => event.id,
      "stream_id" => event.stream_id,
      "event_number" => event.event_number,
      "global_position" => event.global_position,
      "type" => event.type,
      "data" => event.data,
      "metadata" => event.metadata,
      "agent_id" => event.agent_id,
      "causation_id" => event.causation_id,
      "correlation_id" => event.correlation_id,
      "timestamp" => if(event.timestamp, do: DateTime.to_iso8601(event.timestamp))
    }
  end

  @doc false
  def deserialize_event(map) when is_map(map) do
    timestamp =
      case map["timestamp"] do
        nil ->
          nil

        ts when is_binary(ts) ->
          case DateTime.from_iso8601(ts) do
            {:ok, dt, _} -> dt
            _ -> nil
          end

        %DateTime{} = dt ->
          dt
      end

    %Event{
      id: map["id"],
      stream_id: map["stream_id"],
      event_number: map["event_number"],
      global_position: map["global_position"],
      type: map["type"],
      data: map["data"] || %{},
      metadata: map["metadata"] || %{},
      agent_id: map["agent_id"],
      causation_id: map["causation_id"],
      correlation_id: map["correlation_id"],
      timestamp: timestamp
    }
  end

  # --- Snapshot Restore ---

  defp maybe_restore_from_snapshot(state, nil, _opts, _namespace), do: state

  defp maybe_restore_from_snapshot(state, store, store_opts, namespace) do
    meta_key = "#{namespace}:meta"

    case store.get(meta_key, store_opts) do
      {:ok, %{data: meta}} ->
        do_restore_snapshot(state, store, store_opts, namespace, meta)

      {:ok, meta} when is_map(meta) ->
        do_restore_snapshot(state, store, store_opts, namespace, meta)

      _ ->
        Logger.debug("EventLog.ETS: no snapshot meta found, starting fresh")
        state
    end
  rescue
    e ->
      Logger.warning("EventLog.ETS: snapshot restore failed: #{inspect(e)}")
      reset_failed_snapshot_restore(state, :snapshot_restore_failed)
  catch
    :exit, _ ->
      Logger.warning("EventLog.ETS: snapshot store not available")
      reset_failed_snapshot_restore(state, :snapshot_store_unavailable)
  end

  defp do_restore_snapshot(state, store, store_opts, namespace, meta) do
    latest_id = meta["latest_id"]

    if latest_id do
      snapshot_key = "#{namespace}:snapshot:#{latest_id}"

      case store.get(snapshot_key, store_opts) do
        {:ok, %{data: snapshot}} ->
          import_snapshot(state, snapshot)

        {:ok, snapshot} when is_map(snapshot) ->
          import_snapshot(state, snapshot)

        _ ->
          Logger.warning("EventLog.ETS: snapshot #{latest_id} not found")
          reset_failed_snapshot_restore(state, :snapshot_missing)
      end
    else
      state
    end
  end

  defp import_snapshot(state, snapshot) do
    events = Map.get(snapshot, "events", [])
    global_position = Map.get(snapshot, "global_position", 0)
    stream_versions = restore_stream_versions(Map.get(snapshot, "stream_versions", %{}))
    identity_tombstones = Map.get(snapshot, "identity_tombstones")
    declared_identity_history = Map.get(snapshot, "identity_history")

    {identity_entries, snapshot_identity_error} =
      snapshot_identity_entries(events, identity_tombstones, global_position)

    Enum.each(events, fn event_map ->
      event = deserialize_event(event_map)
      # Stream table is pointer-only; global table holds the value.
      :ets.insert(
        state.stream_table,
        {{event.stream_id, event.event_number}, event.global_position}
      )

      :ets.insert(state.global_table, {event.global_position, event})
    end)

    Enum.each(identity_entries, fn {event_id, identity, global_position} ->
      {_fingerprint, stream_id, event_number, ^global_position} = identity
      :ets.insert(state.id_table, {event_id, identity})
      :ets.insert(state.identity_position_table, {global_position, event_id})
      :ets.insert(state.identity_stream_position_table, {{stream_id, event_number}, event_id})
    end)

    event_count = length(events)

    Logger.info(
      "EventLog.ETS: restored #{event_count} events from snapshot (pos: #{global_position})"
    )

    head_inserted_mono =
      Map.new(stream_versions, fn {stream_id, _version} -> {stream_id, :unknown} end)

    restored = %{
      state
      | global_position: global_position,
        stream_versions: stream_versions,
        head_inserted_mono: head_inserted_mono,
        identity_metadata_consistent:
          metadata_sequence_consistent?(stream_versions, global_position)
    }

    identity_history =
      restored_snapshot_identity_history(
        restored,
        events,
        declared_identity_history,
        snapshot_identity_error
      )

    %{restored | identity_history: identity_history}
  end

  # Stream version keys may be atoms or strings depending on serialization
  defp restore_stream_versions(versions) when is_map(versions) do
    Map.new(versions, fn {k, v} -> {k, v} end)
  end

  defp snapshot_identity_entries(events, nil, _global_position) do
    entries =
      Enum.map(events, fn event_map ->
        event = deserialize_event(event_map)
        fingerprint = EventLog.event_fingerprint(event.stream_id, event)

        {event.id, {fingerprint, event.stream_id, event.event_number, event.global_position},
         event.global_position}
      end)

    {entries, nil}
  end

  defp snapshot_identity_entries(events, tombstones, global_position)
       when is_list(tombstones) do
    tombstones
    |> Enum.reduce_while(
      {:ok, [], MapSet.new(), MapSet.new(), MapSet.new()},
      fn tombstone, {:ok, entries, ids, positions, stream_positions} ->
        case snapshot_identity_entry(
               tombstone,
               global_position,
               ids,
               positions,
               stream_positions
             ) do
          {:ok, event_id, identity, position} ->
            {_fingerprint, stream_id, event_number, ^position} = identity
            stream_position = {stream_id, event_number}

            {:cont,
             {:ok, [{event_id, identity, position} | entries], MapSet.put(ids, event_id),
              MapSet.put(positions, position), MapSet.put(stream_positions, stream_position)}}

          :error ->
            {:halt, :error}
        end
      end
    )
    |> case do
      {:ok, entries, _ids, _positions, _stream_positions} ->
        {Enum.reverse(entries), nil}

      :error ->
        {snapshot_event_identity_entries(events), :invalid_snapshot_identity_history}
    end
  end

  defp snapshot_identity_entries(events, _invalid, _global_position),
    do: {snapshot_event_identity_entries(events), :invalid_snapshot_identity_history}

  defp snapshot_event_identity_entries(events) do
    Enum.map(events, fn event_map ->
      event = deserialize_event(event_map)
      fingerprint = EventLog.event_fingerprint(event.stream_id, event)

      {event.id, {fingerprint, event.stream_id, event.event_number, event.global_position},
       event.global_position}
    end)
  end

  defp snapshot_identity_entry(tombstone, global_position, ids, positions, stream_positions) do
    with %{
           "event_id" => event_id,
           "fingerprint" => fingerprint,
           "stream_id" => stream_id,
           "event_number" => event_number,
           "global_position" => position
         } <- tombstone,
         true <- snapshot_identity_string?(event_id),
         true <- valid_snapshot_fingerprint?(fingerprint),
         true <- snapshot_identity_string?(stream_id),
         true <- is_integer(event_number) and event_number > 0,
         true <- is_integer(position) and position > 0 and position <= global_position,
         false <- MapSet.member?(ids, event_id),
         false <- MapSet.member?(positions, position),
         false <- MapSet.member?(stream_positions, {stream_id, event_number}) do
      {:ok, event_id, {fingerprint, stream_id, event_number, position}, position}
    else
      _invalid -> :error
    end
  end

  defp restored_snapshot_identity_history(
         state,
         events,
         declared,
         snapshot_identity_error
       ) do
    complete? =
      is_nil(snapshot_identity_error) and complete_identity_ledger?(state) and
        active_snapshot_events_match?(events, state.id_table)

    case {declared, complete?, snapshot_identity_error} do
      {%{"status" => "complete"}, true, nil} ->
        :complete

      {%{"status" => "unavailable", "reason" => reason}, _complete, nil} ->
        {:unavailable, snapshot_unavailable_reason(reason)}

      {nil, true, nil} ->
        :complete

      {_declared, _complete, :invalid_snapshot_identity_history} ->
        {:unavailable, :invalid_snapshot_identity_history}

      _incomplete ->
        {:unavailable, :legacy_snapshot_incomplete}
    end
  end

  defp active_snapshot_events_match?(events, id_table) do
    Enum.all?(events, fn event_map ->
      event = deserialize_event(event_map)

      case :ets.lookup(id_table, event.id) do
        [
          {_, {fingerprint, stream_id, event_number, global_position}}
        ] ->
          stream_id == event.stream_id and event_number == event.event_number and
            global_position == event.global_position and
            EventLog.event_fingerprint_matches?(stream_id, event, fingerprint)

        _missing_or_invalid ->
          false
      end
    end)
  end

  defp snapshot_unavailable_reason("durable_metadata_only"), do: :durable_metadata_only
  defp snapshot_unavailable_reason("legacy_snapshot_incomplete"), do: :legacy_snapshot_incomplete

  defp snapshot_unavailable_reason("invalid_snapshot_identity_history"),
    do: :invalid_snapshot_identity_history

  defp snapshot_unavailable_reason("snapshot_missing"), do: :snapshot_missing
  defp snapshot_unavailable_reason("snapshot_restore_failed"), do: :snapshot_restore_failed

  defp snapshot_unavailable_reason("snapshot_store_unavailable"),
    do: :snapshot_store_unavailable

  defp snapshot_unavailable_reason("metadata_sequence_inconsistent"),
    do: :metadata_sequence_inconsistent

  defp snapshot_unavailable_reason(_unknown), do: :invalid_snapshot_identity_history

  defp valid_snapshot_fingerprint?(fingerprint) do
    is_binary(fingerprint) and byte_size(fingerprint) == 64 and String.valid?(fingerprint) and
      fingerprint =~ ~r/\A[0-9a-f]{64}\z/
  end

  defp snapshot_identity_string?(value) do
    is_binary(value) and byte_size(value) > 0 and byte_size(value) <= 255 and
      String.valid?(value)
  end

  defp reset_failed_snapshot_restore(state, reason) do
    Enum.each(
      [
        state.stream_table,
        state.global_table,
        state.id_table,
        state.identity_position_table,
        state.identity_stream_position_table
      ],
      &:ets.delete_all_objects/1
    )

    %{
      state
      | global_position: 0,
        stream_versions: %{},
        head_inserted_mono: %{},
        identity_metadata_consistent: false,
        identity_history: {:unavailable, reason}
    }
  end
end
