defmodule Arbor.Consensus.EventStore do
  @moduledoc """
  ETS-backed append-only event store for consensus audit trails.

  Stores `ConsensusEvent` structs with query support by proposal_id,
  event_type, agent_id, and time range. Optionally forwards events
  to an `EventSink` for external persistence.

  ## Capacity

  Maximum 10,000 events with oldest-first pruning when capacity is reached.
  """

  use GenServer

  alias Arbor.Contracts.Consensus.ConsensusEvent
  alias Arbor.Consensus.EventConverter
  alias Arbor.Persistence.EventLog.ETS, as: PersistenceETS

  require Logger

  @max_events 10_000
  @table_name :arbor_consensus_events

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Start the event store.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Append an event to the store.
  """
  @spec append(ConsensusEvent.t(), GenServer.server()) :: :ok
  def append(%ConsensusEvent{} = event, server \\ __MODULE__) do
    GenServer.call(server, {:append, event})
  end

  @doc """
  Query events with filters.

  ## Options

    * `:proposal_id` - Filter by proposal ID
    * `:event_type` - Filter by event type atom
    * `:agent_id` - Filter by agent ID
    * `:since` - Filter events after this DateTime
    * `:until` - Filter events before this DateTime
    * `:limit` - Maximum number of events to return (default: 100)
  """
  @spec query(keyword(), GenServer.server()) :: [ConsensusEvent.t()]
  def query(filters \\ [], server \\ __MODULE__) do
    GenServer.call(server, {:query, filters})
  end

  @doc """
  Get all events for a proposal, ordered by timestamp.
  """
  @spec get_by_proposal(String.t(), GenServer.server()) :: [ConsensusEvent.t()]
  def get_by_proposal(proposal_id, server \\ __MODULE__) do
    query([proposal_id: proposal_id], server)
  end

  @doc """
  Get a chronological timeline of events for a proposal.
  Returns events with their index in the proposal's lifecycle.
  """
  @spec get_timeline(String.t(), GenServer.server()) :: [{non_neg_integer(), ConsensusEvent.t()}]
  def get_timeline(proposal_id, server \\ __MODULE__) do
    proposal_id
    |> get_by_proposal(server)
    |> Enum.sort_by(& &1.timestamp, DateTime)
    |> Enum.with_index()
    |> Enum.map(fn {event, idx} -> {idx, event} end)
  end

  @doc """
  Get the total count of stored events.
  """
  @spec count(GenServer.server()) :: non_neg_integer()
  def count(server \\ __MODULE__) do
    GenServer.call(server, :count)
  end

  @doc """
  Clear all events (useful for testing).
  """
  @spec clear(GenServer.server()) :: :ok
  def clear(server \\ __MODULE__) do
    GenServer.call(server, :clear)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table_name, @table_name)
    event_sink = Keyword.get(opts, :event_sink)
    max_events = Keyword.get(opts, :max_events, @max_events)
    event_log = Keyword.get(opts, :event_log)

    table = :ets.new(table_name, [:ordered_set, :protected, :named_table])

    state = %{
      table: table,
      event_sink: event_sink,
      event_log: event_log,
      max_events: max_events,
      counter: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:append, event}, _from, state) do
    # Use counter as key for ordered insertion
    counter = state.counter + 1
    :ets.insert(state.table, {counter, event})

    # Prune if over capacity
    state =
      if counter > state.max_events do
        prune(state)
      else
        state
      end

    # Persist to unified EventLog (durable write)
    persist_to_event_log(event, state)

    # Emit signal (notification)
    emit_consensus_signal(event)

    # Forward to event sink if configured (deprecated path)
    if state.event_sink do
      forward_to_sink(state.event_sink, event)
    end

    {:reply, :ok, %{state | counter: counter}}
  end

  @impl true
  def handle_call({:query, filters}, _from, state) do
    limit = Keyword.get(filters, :limit, 100)

    events =
      state.table
      |> ets_to_list()
      |> apply_filters(filters)
      |> Enum.sort_by(& &1.timestamp, DateTime)
      |> Enum.take(limit)

    {:reply, events, state}
  end

  @impl true
  def handle_call(:count, _from, state) do
    {:reply, :ets.info(state.table, :size), state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, %{state | counter: 0}}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp ets_to_list(table) do
    :ets.tab2list(table)
    |> Enum.map(fn {_key, event} -> event end)
  end

  defp apply_filters(events, filters) do
    Enum.reduce(filters, events, fn
      {:proposal_id, id}, acc ->
        Enum.filter(acc, &(&1.proposal_id == id))

      {:event_type, type}, acc ->
        Enum.filter(acc, &(&1.event_type == type))

      {:agent_id, id}, acc ->
        Enum.filter(acc, &(&1.agent_id == id))

      {:since, dt}, acc ->
        Enum.filter(acc, &(DateTime.compare(&1.timestamp, dt) in [:gt, :eq]))

      {:until, dt}, acc ->
        Enum.filter(acc, &(DateTime.compare(&1.timestamp, dt) in [:lt, :eq]))

      {:limit, _}, acc ->
        acc

      _, acc ->
        acc
    end)
  end

  defp prune(state) do
    # Remove oldest 10% of events
    prune_count = div(state.max_events, 10)

    state.table
    |> :ets.tab2list()
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.take(prune_count)
    |> Enum.each(fn {key, _} -> :ets.delete(state.table, key) end)

    state
  end

  defp forward_to_sink(sink_module, event) do
    Task.start(fn ->
      case sink_module.record(event) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "EventSink #{inspect(sink_module)} failed to record event #{event.id}: #{inspect(reason)}"
          )
      end
    end)
  end

  defp persist_to_event_log(_event, %{event_log: nil}), do: :ok

  defp persist_to_event_log(%ConsensusEvent{} = event, %{event_log: event_log}) do
    persistence_event = EventConverter.to_persistence_event(event)
    stream_id = EventConverter.stream_id(event)

    case PersistenceETS.append(stream_id, persistence_event, name: event_log) do
      {:ok, _persisted} -> :ok
      {:error, reason} ->
        Logger.warning("Consensus.EventStore: failed to persist to EventLog: #{inspect(reason)}")
        :ok
    end
  end

  defp emit_consensus_signal(%ConsensusEvent{} = event) do
    Arbor.Signals.emit(
      :consensus,
      event.event_type,
      ConsensusEvent.to_map(event),
      source: "arbor.consensus"
    )
  rescue
    _ -> :ok
  end
end
