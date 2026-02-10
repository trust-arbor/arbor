defmodule Arbor.Persistence.EventLog.ETS do
  @moduledoc """
  ETS-backed implementation of the EventLog behaviour.

  Uses two ETS tables:
  - Stream table (`:ordered_set`): keyed by `{stream_id, event_number}` for per-stream reads
  - Global table (`:ordered_set`): keyed by `global_position` for cross-stream reads

  Supports subscriber notifications via pid monitoring.

      children = [
        {Arbor.Persistence.EventLog.ETS, name: :my_event_log}
      ]
  """

  use GenServer

  require Logger

  @behaviour Arbor.Persistence.EventLog

  alias Arbor.Persistence.Event

  @default_max_events 1_000_000
  @default_max_read 10_000
  @warning_threshold 0.8

  # --- Client API (EventLog behaviour) ---

  @impl Arbor.Persistence.EventLog
  def append(stream_id, events, opts) do
    name = Keyword.fetch!(opts, :name)
    events = List.wrap(events)
    GenServer.call(name, {:append, stream_id, events})
  end

  @impl Arbor.Persistence.EventLog
  def read_stream(stream_id, opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, {:read_stream, stream_id, opts})
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
    stream_table =
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      :ets.new(:"#{name}_streams", [:ordered_set, :protected, read_concurrency: true])

    # Safe: name is module atom from internal start_link opts, not user input
    global_table =
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      :ets.new(:"#{name}_global", [:ordered_set, :protected, read_concurrency: true])

    base_state = %{
      stream_table: stream_table,
      global_table: global_table,
      global_position: 0,
      max_events: max_events,
      warning_logged: false,
      stream_versions: %{},
      subscribers: %{},
      monitors: %{}
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

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:append, stream_id, events}, _from, state) do
    if state.global_position + length(events) > state.max_events do
      {:reply, {:error, :event_log_full}, state}
    else
      {persisted, state} = do_append(stream_id, events, state)
      notify_subscribers(stream_id, persisted, state)
      state = maybe_warn_event_capacity(state)
      {:reply, {:ok, persisted}, state}
    end
  end

  def handle_call({:read_stream, stream_id, opts}, _from, state) do
    from_num = Keyword.get(opts, :from, 0)
    limit = Keyword.get(opts, :limit)
    direction = Keyword.get(opts, :direction, :forward)

    events = do_read_stream(state.stream_table, stream_id, from_num, limit, direction)
    {:reply, {:ok, events}, state}
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

  # --- Private ---

  defp remove_subscriber(subscribers, sub_key, pid, ref) do
    Map.update(subscribers, sub_key, [], fn subs ->
      Enum.reject(subs, fn {p, r} -> p == pid and r == ref end)
    end)
  end

  defp decrement_limit(nil), do: nil
  defp decrement_limit(n), do: n - 1

  defp do_append(stream_id, events, state) do
    current_version = Map.get(state.stream_versions, stream_id, 0)

    {persisted, final_version, final_global} =
      events
      |> Enum.reduce({[], current_version, state.global_position}, fn %Event{} = event, {acc, ver, gpos} ->
        new_ver = ver + 1
        new_gpos = gpos + 1

        persisted_event = %Event{
          event
          | event_number: new_ver,
            global_position: new_gpos,
            stream_id: stream_id
        }

        :ets.insert(state.stream_table, {{stream_id, new_ver}, persisted_event})
        :ets.insert(state.global_table, {new_gpos, persisted_event})

        {[persisted_event | acc], new_ver, new_gpos}
      end)

    persisted = Enum.reverse(persisted)

    state = %{
      state
      | global_position: final_global,
        stream_versions: Map.put(state.stream_versions, stream_id, final_version)
    }

    {persisted, state}
  end

  defp do_read_stream(table, stream_id, from_num, limit, direction) do
    # Collect all events for this stream from from_num onwards
    events = collect_stream_events(table, stream_id, from_num, [])

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

  defp collect_stream_events(table, stream_id, from_num, acc) do
    key = {stream_id, from_num}

    case :ets.lookup(table, key) do
      [{^key, event}] ->
        collect_stream_events(table, stream_id, from_num + 1, [event | acc])

      [] ->
        # Check if there's a next key in this stream (handles from_num=0 case)
        case :ets.next(table, key) do
          {^stream_id, next_num} ->
            collect_stream_events(table, stream_id, next_num, acc)

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
        nil -> nil
        ts when is_binary(ts) ->
          case DateTime.from_iso8601(ts) do
            {:ok, dt, _} -> dt
            _ -> nil
          end
        %DateTime{} = dt -> dt
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
      :ets.insert(state.stream_table, {{event.stream_id, event.event_number}, event})
      :ets.insert(state.global_table, {event.global_position, event})
    end)

    event_count = length(events)
    Logger.info("EventLog.ETS: restored #{event_count} events from snapshot (pos: #{global_position})")

    %{state | global_position: global_position, stream_versions: stream_versions}
  end

  # Stream version keys may be atoms or strings depending on serialization
  defp restore_stream_versions(versions) when is_map(versions) do
    Map.new(versions, fn {k, v} -> {k, v} end)
  end
end
