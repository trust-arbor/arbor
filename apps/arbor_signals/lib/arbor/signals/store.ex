defmodule Arbor.Signals.Store do
  @moduledoc """
  In-memory signal storage with configurable retention.

  Stores signals in a circular buffer with automatic cleanup of old signals.
  Supports querying by ID and filtering by various criteria.

  ## Configuration

  - `:max_signals` - Maximum signals to retain (default: 10_000)
  - `:ttl_seconds` - Time-to-live in seconds (default: 3600)
  """

  use GenServer

  alias Arbor.Signals.Signal

  @default_max_signals 10_000
  @default_ttl_seconds 3600
  @cleanup_interval_ms 60_000

  # Client API

  @doc """
  Start the signal store.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Store a signal.
  """
  @spec put(Signal.t()) :: :ok
  def put(%Signal{} = signal) do
    GenServer.cast(__MODULE__, {:put, signal})
  end

  @doc """
  Get a signal by ID.
  """
  @spec get(String.t()) :: {:ok, Signal.t()} | {:error, :not_found}
  def get(signal_id) do
    GenServer.call(__MODULE__, {:get, signal_id})
  end

  @doc """
  Query signals with filters.

  ## Options

  - `:category` - Filter by category (atom or list)
  - `:type` - Filter by type (atom or list)
  - `:source` - Filter by source
  - `:since` - Only signals after DateTime
  - `:until` - Only signals before DateTime
  - `:correlation_id` - Filter by correlation ID
  - `:limit` - Maximum signals to return (default: 100)
  """
  @spec query(keyword()) :: {:ok, [Signal.t()]}
  def query(filters \\ []) do
    GenServer.call(__MODULE__, {:query, filters})
  end

  @doc """
  Get recent signals.

  ## Options

  - `:limit` - Maximum signals to return (default: 50)
  - `:category` - Filter by category
  - `:type` - Filter by type
  """
  @spec recent(keyword()) :: {:ok, [Signal.t()]}
  def recent(opts \\ []) do
    GenServer.call(__MODULE__, {:recent, opts})
  end

  @doc """
  Get store statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Clear all signals.
  """
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    max_signals = Keyword.get(opts, :max_signals, @default_max_signals)
    ttl_seconds = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)

    schedule_cleanup()

    {:ok,
     %{
       signals: %{},
       order: :queue.new(),
       max_signals: max_signals,
       ttl_seconds: ttl_seconds,
       stats: %{
         total_stored: 0,
         total_expired: 0,
         total_evicted: 0
       }
     }}
  end

  @impl true
  def handle_cast({:put, signal}, state) do
    state =
      state
      |> add_signal(signal)
      |> maybe_evict()

    {:noreply, state}
  end

  @impl true
  def handle_call({:get, signal_id}, _from, state) do
    result =
      case Map.get(state.signals, signal_id) do
        nil -> {:error, :not_found}
        signal -> {:ok, signal}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:query, filters}, _from, state) do
    limit = Keyword.get(filters, :limit, 100)
    filters = Keyword.delete(filters, :limit)

    signals =
      state.signals
      |> Map.values()
      |> Enum.filter(&Signal.matches?(&1, filters))
      |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
      |> Enum.take(limit)

    {:reply, {:ok, signals}, state}
  end

  @impl true
  def handle_call({:recent, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 50)
    filters = Keyword.drop(opts, [:limit])

    signals =
      state.order
      |> :queue.to_list()
      |> Enum.reverse()
      |> Enum.take(limit * 2)
      |> Enum.map(&Map.get(state.signals, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&Signal.matches?(&1, filters))
      |> Enum.take(limit)

    {:reply, {:ok, signals}, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        current_count: map_size(state.signals),
        max_signals: state.max_signals,
        ttl_seconds: state.ttl_seconds
      })

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | signals: %{}, order: :queue.new()}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    state = cleanup_expired(state)
    schedule_cleanup()
    {:noreply, state}
  end

  # Private functions

  defp add_signal(state, signal) do
    stats = Map.update!(state.stats, :total_stored, &(&1 + 1))

    %{
      state
      | signals: Map.put(state.signals, signal.id, signal),
        order: :queue.in(signal.id, state.order),
        stats: stats
    }
  end

  defp maybe_evict(state) do
    if map_size(state.signals) > state.max_signals do
      evict_oldest(state)
    else
      state
    end
  end

  defp evict_oldest(state) do
    case :queue.out(state.order) do
      {{:value, signal_id}, new_order} ->
        stats = Map.update!(state.stats, :total_evicted, &(&1 + 1))

        %{
          state
          | signals: Map.delete(state.signals, signal_id),
            order: new_order,
            stats: stats
        }

      {:empty, _} ->
        state
    end
  end

  defp cleanup_expired(state) do
    cutoff = DateTime.add(DateTime.utc_now(), -state.ttl_seconds, :second)

    {expired_ids, remaining_signals} =
      Enum.split_with(state.signals, fn {_id, signal} ->
        DateTime.compare(signal.timestamp, cutoff) == :lt
      end)

    expired_count = length(expired_ids)
    expired_id_set = expired_ids |> Enum.map(fn {id, _} -> id end) |> MapSet.new()

    new_order =
      state.order
      |> :queue.to_list()
      |> Enum.reject(&MapSet.member?(expired_id_set, &1))
      |> :queue.from_list()

    stats = Map.update!(state.stats, :total_expired, &(&1 + expired_count))

    %{
      state
      | signals: Map.new(remaining_signals),
        order: new_order,
        stats: stats
    }
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
