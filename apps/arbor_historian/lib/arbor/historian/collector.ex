defmodule Arbor.Historian.Collector do
  @moduledoc """
  GenServer that subscribes to the Signals Bus and persists events.

  On init, subscribes to all signals (`"*"` pattern). For each received signal:
  1. Transforms it into an Event via SignalTransformer
  2. Routes it to applicable streams via StreamRouter
  3. Appends the event to each stream in the EventLog
  4. Updates the StreamRegistry with new metadata

  ## Options

  - `:event_log` - PID or name of the EventLog process (default: `EventLog.ETS`)
  - `:registry` - PID or name of the StreamRegistry (default: `StreamRegistry`)
  - `:filter` - Optional `(signal -> boolean)` to exclude signals
  - `:subscribe` - Whether to subscribe on init (default: true, set false for testing)
  """

  use GenServer

  alias Arbor.Historian.Collector.{SignalTransformer, StreamRouter}
  alias Arbor.Historian.EventConverter
  alias Arbor.Historian.StreamRegistry
  alias Arbor.Persistence.EventLog.ETS, as: PersistenceETS

  require Logger

  defstruct [
    :event_log,
    :registry,
    :subscription_id,
    :filter,
    :event_count
  ]

  # Client API

  @doc "Start the Collector."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Manually collect a signal (useful for testing or replaying)."
  @spec collect(GenServer.server(), struct()) :: :ok | {:error, term()}
  def collect(server \\ __MODULE__, signal) do
    GenServer.call(server, {:collect, signal})
  end

  @doc "Get the number of events collected."
  @spec event_count(GenServer.server()) :: non_neg_integer()
  def event_count(server \\ __MODULE__) do
    GenServer.call(server, :event_count)
  end

  @doc "Get collector stats."
  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__) do
    GenServer.call(server, :stats)
  end

  # Server callbacks

  @impl GenServer
  def init(opts) do
    event_log = Keyword.get(opts, :event_log, Arbor.Historian.EventLog.ETS)
    registry = Keyword.get(opts, :registry, StreamRegistry)
    filter = Keyword.get(opts, :filter)
    subscribe? = Keyword.get(opts, :subscribe, true)

    state = %__MODULE__{
      event_log: event_log,
      registry: registry,
      filter: filter,
      event_count: 0
    }

    if subscribe? do
      case subscribe_to_signals() do
        {:ok, sub_id} ->
          {:ok, %{state | subscription_id: sub_id}}

        {:error, reason} ->
          Logger.warning("Historian Collector failed to subscribe to signals: #{inspect(reason)}")
          {:ok, state}
      end
    else
      {:ok, state}
    end
  end

  @impl GenServer
  def handle_call({:collect, signal}, _from, state) do
    case process_signal(signal, state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call(:event_count, _from, state) do
    {:reply, state.event_count, state}
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    stats = %{
      event_count: state.event_count,
      subscribed: state.subscription_id != nil,
      event_log: state.event_log,
      registry: state.registry
    }

    {:reply, stats, state}
  end

  @impl GenServer
  def handle_info({:signal, signal}, state) do
    case process_signal(signal, state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _reason} -> {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{subscription_id: sub_id}) when is_binary(sub_id) do
    try do
      Arbor.Signals.unsubscribe(sub_id)
    rescue
      _ -> :ok
    end
  end

  def terminate(_reason, _state), do: :ok

  # Private

  defp subscribe_to_signals do
    collector_pid = self()

    handler = fn signal ->
      send(collector_pid, {:signal, signal})
      :ok
    end

    Arbor.Signals.subscribe("*", handler, async: true)
  rescue
    e -> {:error, e}
  end

  defp process_signal(signal, state) do
    if should_collect?(signal, state) do
      stream_ids = StreamRouter.route(signal)
      primary_stream = List.first(stream_ids)

      case SignalTransformer.signal_to_event(signal, primary_stream) do
        {:ok, event} ->
          append_to_streams(event, stream_ids, signal, state)

        {:error, reason} ->
          Logger.debug("Historian: failed to transform signal: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:ok, state}
    end
  end

  defp should_collect?(_signal, %{filter: nil}), do: true

  defp should_collect?(signal, %{filter: filter}) when is_function(filter, 1) do
    filter.(signal)
  rescue
    _ -> true
  end

  defp append_to_streams(event, stream_ids, signal, state) do
    timestamp = Map.get(signal, :timestamp) || Map.get(signal, :time) || DateTime.utc_now()

    Enum.each(stream_ids, fn stream_id ->
      stream_event = %{event | stream_id: stream_id, subject_id: stream_id}
      persistence_event = EventConverter.to_persistence_event(stream_event, stream_id)

      case PersistenceETS.append(stream_id, persistence_event, name: state.event_log) do
        {:ok, _persisted} ->
          StreamRegistry.record_event(state.registry, stream_id, timestamp)

        {:error, reason} ->
          Logger.debug("Historian: failed to append to #{stream_id}: #{inspect(reason)}")
      end
    end)

    {:ok, %{state | event_count: state.event_count + 1}}
  end
end
