defmodule Arbor.Persistence.Ecto.EventStore do
  @moduledoc """
  Postgres-backed event store using the `eventstore` library.

  This module defines the event store that will be used for durable
  event persistence. It uses the battle-tested `eventstore` library
  which is also the backend for Commanded.

  ## Configuration

  Configure in your application's config:

      config :arbor_persistence_ecto, Arbor.Persistence.Ecto.EventStore,
        serializer: EventStore.JsonSerializer,
        schema_prefix: "trust_arbor",
        column_data_type: "jsonb",
        username: "postgres",
        password: "postgres",
        database: "arbor_eventstore",
        hostname: "localhost",
        pool_size: 10

  ## Setup

  Create and initialize the event store:

      mix event_store.create -e Arbor.Persistence.Ecto.EventStore
      mix event_store.init -e Arbor.Persistence.Ecto.EventStore

  Or use the alias:

      mix event_store.setup

  ## Usage

  Start the event store in your supervision tree:

      children = [
        Arbor.Persistence.Ecto.EventStore
      ]

  Then use via the `Arbor.Persistence.Ecto.EventLog` adapter which
  implements the `Arbor.Contracts.API.Persistence.EventLog` behaviour.
  """

  use EventStore, otp_app: :arbor_persistence_ecto
end
