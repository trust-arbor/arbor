defmodule Arbor.Historian.EventLog.ETS do
  @moduledoc """
  ETS-backed event log for in-memory event storage.

  Maintains two ETS tables:
  - Stream table: `{stream_id, position, event}` ordered by position
  - Global table: `{global_position, stream_id, event}` for cross-stream reads

  Suitable for development, testing, and single-node deployments.
  """

  use GenServer

  @behaviour Arbor.Historian.EventLog

  alias Arbor.Contracts.Events.Event

  defstruct [:streams_table, :global_table, :global_counter, :stream_counters]

  # Client API

  @impl Arbor.Historian.EventLog
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl Arbor.Historian.EventLog
  def append(server, stream_id, %Event{} = event) do
    GenServer.call(server, {:append, stream_id, event})
  end

  @impl Arbor.Historian.EventLog
  def read_stream(server, stream_id) do
    GenServer.call(server, {:read_stream, stream_id})
  end

  @impl Arbor.Historian.EventLog
  def read_all(server) do
    GenServer.call(server, :read_all)
  end

  @impl Arbor.Historian.EventLog
  def list_streams(server) do
    GenServer.call(server, :list_streams)
  end

  @impl Arbor.Historian.EventLog
  def stream_size(server, stream_id) do
    GenServer.call(server, {:stream_size, stream_id})
  end

  @impl Arbor.Historian.EventLog
  def total_size(server) do
    GenServer.call(server, :total_size)
  end

  # Server callbacks

  @impl GenServer
  def init(_opts) do
    streams = :ets.new(:historian_streams, [:ordered_set, :private])
    global = :ets.new(:historian_global, [:ordered_set, :private])

    state = %__MODULE__{
      streams_table: streams,
      global_table: global,
      global_counter: 0,
      stream_counters: %{}
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:append, stream_id, event}, _from, state) do
    stream_pos = Map.get(state.stream_counters, stream_id, 0)
    global_pos = state.global_counter

    positioned_event =
      Event.set_position(event, stream_id, stream_pos, global_pos)

    :ets.insert(state.streams_table, {{stream_id, stream_pos}, positioned_event})
    :ets.insert(state.global_table, {global_pos, stream_id, positioned_event})

    new_state = %{
      state
      | global_counter: global_pos + 1,
        stream_counters: Map.put(state.stream_counters, stream_id, stream_pos + 1)
    }

    {:reply, {:ok, stream_pos}, new_state}
  end

  @impl GenServer
  def handle_call({:read_stream, stream_id}, _from, state) do
    events =
      :ets.select(state.streams_table, [
        {{{stream_id, :_}, :"$1"}, [], [:"$1"]}
      ])

    {:reply, {:ok, events}, state}
  end

  @impl GenServer
  def handle_call(:read_all, _from, state) do
    events =
      :ets.tab2list(state.global_table)
      |> Enum.sort_by(fn {pos, _sid, _event} -> pos end)
      |> Enum.map(fn {_pos, _sid, event} -> event end)

    {:reply, {:ok, events}, state}
  end

  @impl GenServer
  def handle_call(:list_streams, _from, state) do
    {:reply, {:ok, Map.keys(state.stream_counters)}, state}
  end

  @impl GenServer
  def handle_call({:stream_size, stream_id}, _from, state) do
    {:reply, {:ok, Map.get(state.stream_counters, stream_id, 0)}, state}
  end

  @impl GenServer
  def handle_call(:total_size, _from, state) do
    {:reply, {:ok, state.global_counter}, state}
  end
end
