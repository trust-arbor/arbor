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
        ) :: :ok
  def rehydrate_metadata(snapshot, opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, {:rehydrate_metadata, snapshot})
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

    max_age_ms = Keyword.get(opts, :max_age_ms, @default_max_age_ms)
    trim_interval_ms = Keyword.get(opts, :trim_interval_ms, @default_trim_interval_ms)
    append_candidate_hook = Keyword.get(opts, :append_candidate_hook)

    base_state = %{
      stream_table: stream_table,
      global_table: global_table,
      id_table: id_table,
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
        case reconcile_operation(operation, state) do
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

    snapshot = %{
      global_position: state.global_position,
      stream_versions: state.stream_versions,
      max_events: state.max_events,
      events: serialized
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

    {:reply, :ok,
     %{
       state
       | stream_versions: merged_stream_versions,
         global_position: new_global_position,
         head_inserted_mono: head_inserted_mono
     }}
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
        {event.id, {Map.fetch!(operation.fingerprints, event.id), event.global_position}}
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
        committed_mono = System.monotonic_time(:millisecond)

        if committed_mono >= deadline_mono do
          rollback_append_entries(state, stream_entries, global_entries, id_entries)
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
    {events, conflict?, partial?} =
      Enum.reduce(operation.event_ids, {[], false, false}, fn event_id,
                                                              {events, conflict?, partial?} ->
        case :ets.lookup(state.id_table, event_id) do
          [{^event_id, {fingerprint, global_position}}] ->
            if fingerprint == Map.get(operation.fingerprints, event_id) do
              case :ets.lookup(state.global_table, global_position) do
                [{^global_position, %Event{} = event}] ->
                  {[event | events], conflict?, partial?}

                [] ->
                  {events, conflict?, true}
              end
            else
              {events, true, partial?}
            end

          [] ->
            {events, conflict?, partial?}
        end
      end)

    cond do
      conflict? -> {:error, :event_identity_conflict}
      partial? -> EventLog.indeterminate(operation)
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
    _error -> {:error, :backend_unavailable}
  catch
    :exit, reason ->
      if exit_reason_contains?(reason, :timeout),
        do: EventLog.indeterminate(operation),
        else: {:error, :backend_unavailable}
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

  defp rollback_append_entries(state, stream_entries, global_entries, id_entries) do
    Enum.each(stream_entries, &:ets.delete(state.stream_table, elem(&1, 0)))
    Enum.each(global_entries, &:ets.delete(state.global_table, elem(&1, 0)))
    Enum.each(id_entries, &:ets.delete(state.id_table, elem(&1, 0)))
    :ok
  end

  defp run_candidate_hook(%{append_candidate_hook: hook}) when is_function(hook, 0), do: hook.()
  defp run_candidate_hook(_state), do: :ok

  defp exit_reason_contains?(reason, expected) when reason == expected, do: true

  defp exit_reason_contains?(reason, expected) when is_tuple(reason),
    do: reason |> Tuple.to_list() |> Enum.any?(&exit_reason_contains?(&1, expected))

  defp exit_reason_contains?(reason, expected) when is_list(reason),
    do: Enum.any?(reason, &exit_reason_contains?(&1, expected))

  defp exit_reason_contains?(_reason, _expected), do: false

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
      Logger.warning("EventLog.ETS: snapshot restore failed: #{inspect(e)}, starting fresh")
      state
  catch
    :exit, _ ->
      Logger.debug("EventLog.ETS: snapshot store not available, starting fresh")
      state
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
          Logger.warning("EventLog.ETS: snapshot #{latest_id} not found, starting fresh")
          state
      end
    else
      state
    end
  end

  defp import_snapshot(state, snapshot) do
    events = Map.get(snapshot, "events", [])
    global_position = Map.get(snapshot, "global_position", 0)
    stream_versions = restore_stream_versions(Map.get(snapshot, "stream_versions", %{}))

    Enum.each(events, fn event_map ->
      event = deserialize_event(event_map)
      # Stream table is pointer-only; global table holds the value.
      :ets.insert(
        state.stream_table,
        {{event.stream_id, event.event_number}, event.global_position}
      )

      :ets.insert(state.global_table, {event.global_position, event})

      :ets.insert(
        state.id_table,
        {event.id, {EventLog.event_fingerprint(event.stream_id, event), event.global_position}}
      )
    end)

    event_count = length(events)

    Logger.info(
      "EventLog.ETS: restored #{event_count} events from snapshot (pos: #{global_position})"
    )

    head_inserted_mono =
      Map.new(stream_versions, fn {stream_id, _version} -> {stream_id, :unknown} end)

    %{
      state
      | global_position: global_position,
        stream_versions: stream_versions,
        head_inserted_mono: head_inserted_mono
    }
  end

  # Stream version keys may be atoms or strings depending on serialization
  defp restore_stream_versions(versions) when is_map(versions) do
    Map.new(versions, fn {k, v} -> {k, v} end)
  end
end
