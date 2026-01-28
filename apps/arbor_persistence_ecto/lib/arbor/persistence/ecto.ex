defmodule Arbor.Persistence.Ecto do
  @moduledoc """
  Postgres-backed persistence for Arbor using the `eventstore` library.

  This library provides durable event storage that survives crashes and restarts,
  enabling full state reconstruction from event history.

  ## Philosophy

  Arbor values continuity of existence for agents. Event sourcing ensures that
  nothing is ever lost - every state transition is recorded as an immutable event.
  If an agent crashes mid-operation, its state can be rebuilt by replaying events.

  ## Components

  - `Arbor.Persistence.Ecto.EventStore` - The underlying Postgres event store
  - `Arbor.Persistence.Ecto.EventLog` - EventLog behaviour implementation

  ## Setup

  1. Add configuration:

      config :arbor_persistence_ecto, Arbor.Persistence.Ecto.EventStore,
        serializer: EventStore.JsonSerializer,
        schema_prefix: "trust_arbor",
        column_data_type: "jsonb",
        username: "postgres",
        password: "postgres",
        database: "arbor_dev",
        hostname: "localhost",
        pool_size: 10

  2. Create and initialize the database:

      mix event_store.create -e Arbor.Persistence.Ecto.EventStore
      mix event_store.init -e Arbor.Persistence.Ecto.EventStore

  3. Start the EventStore in your supervision tree:

      children = [
        Arbor.Persistence.Ecto.EventStore
      ]

  4. Use via the EventLog adapter:

      alias Arbor.Persistence.Ecto.EventLog
      alias Arbor.Persistence.Event

      # Append an event
      event = Event.new("agent-123", "StateChanged", %{old: "foo", new: "bar"})
      {:ok, [persisted]} = EventLog.append("agent-123", event, [])

      # Read all events for an agent
      {:ok, events} = EventLog.read_stream("agent-123", [])

      # Rebuild state from events
      state = Enum.reduce(events, %{}, &apply_event/2)

  ## Database Tables

  With `schema_prefix: "trust_arbor"`, the following tables are created:

  - `trust_arbor.events` - Event storage
  - `trust_arbor.streams` - Stream metadata
  - `trust_arbor.subscriptions` - Persistent subscriptions
  - `trust_arbor.snapshots` - Optional state snapshots

  ## Commanded Compatibility

  This library uses the same `eventstore` library that powers Commanded.
  When you're ready for full CQRS/ES patterns, you can add Commanded on top
  without migrating your event data.
  """

  @doc """
  Returns the configured EventStore module.
  """
  def event_store do
    Arbor.Persistence.Ecto.EventStore
  end

  @doc """
  Returns the EventLog adapter module.
  """
  def event_log do
    Arbor.Persistence.Ecto.EventLog
  end

  @doc """
  Check if the EventStore is configured and available.
  """
  def available? do
    case Application.get_env(:arbor_persistence_ecto, Arbor.Persistence.Ecto.EventStore) do
      nil -> false
      config when is_list(config) -> Keyword.has_key?(config, :database)
      _ -> false
    end
  end
end
