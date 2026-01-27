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

  @behaviour Arbor.Persistence.EventLog

  alias Arbor.Persistence.Event

  # --- Client API (EventLog behaviour) ---

  @impl Arbor.Persistence.EventLog
  def append(stream_id, events, opts \\ []) do
    name = Keyword.fetch!(opts, :name)
    events = List.wrap(events)
    GenServer.call(name, {:append, stream_id, events})
  end

  @impl Arbor.Persistence.EventLog
  def read_stream(stream_id, opts \\ []) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, {:read_stream, stream_id, opts})
  end

  @impl Arbor.Persistence.EventLog
  def read_all(opts \\ []) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, {:read_all, opts})
  end

  @impl Arbor.Persistence.EventLog
  def stream_exists?(stream_id, opts \\ []) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, {:stream_exists?, stream_id})
  end

  @impl Arbor.Persistence.EventLog
  def stream_version(stream_id, opts \\ []) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, {:stream_version, stream_id})
  end

  @impl Arbor.Persistence.EventLog
  def subscribe(stream_id_or_all, pid, opts \\ []) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, {:subscribe, stream_id_or_all, pid})
  end

  # --- GenServer ---

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    stream_table =
      :ets.new(:"#{name}_streams", [:ordered_set, :protected, read_concurrency: true])

    global_table =
      :ets.new(:"#{name}_global", [:ordered_set, :protected, read_concurrency: true])

    {:ok,
     %{
       stream_table: stream_table,
       global_table: global_table,
       global_position: 0,
       stream_versions: %{},
       subscribers: %{},
       monitors: %{}
     }}
  end

  @impl GenServer
  def handle_call({:append, stream_id, events}, _from, state) do
    {persisted, state} = do_append(stream_id, events, state)
    notify_subscribers(stream_id, persisted, state)
    {:reply, {:ok, persisted}, state}
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
    limit = Keyword.get(opts, :limit)

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

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, monitors} ->
        {:noreply, %{state | monitors: monitors}}

      {{sub_key, pid}, monitors} ->
        subscribers =
          Map.update(state.subscribers, sub_key, [], fn subs ->
            Enum.reject(subs, fn {p, r} -> p == pid and r == ref end)
          end)

        {:noreply, %{state | subscribers: subscribers, monitors: monitors}}
    end
  end

  # --- Private ---

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
        new_limit = if limit, do: limit - 1, else: nil
        collect_global_events(table, pos + 1, new_limit, [event | acc])

      [] ->
        # Try next position (gaps shouldn't exist but handle gracefully)
        case :ets.next(table, pos) do
          :"$end_of_table" ->
            acc

          next_pos when is_integer(next_pos) ->
            [{^next_pos, event}] = :ets.lookup(table, next_pos)
            new_limit = if limit, do: limit - 1, else: nil
            collect_global_events(table, next_pos + 1, new_limit, [event | acc])

          _ ->
            acc
        end
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
end
