# Arbor Persistence EventStore

An optional PostgreSQL EventStore adapter for the core EventLog protocol. It
depends on `arbor_persistence` and public libraries, with no dependency on the
Arbor host, Kernel, Security, Signals or SQL adapter.

Module names remain `Arbor.Persistence.Ecto.*`. Configuration is owned by
`:arbor_persistence_eventstore`:

```elixir
config :arbor_persistence_eventstore, Arbor.Persistence.Ecto.EventStore,
  database: "my_events",
  username: "postgres",
  hostname: "127.0.0.1",
  serializer: Arbor.Persistence.Ecto.EventSerializer
```

The application starts an empty supervisor. Consumers explicitly initialize
their own database/schema, run `mix arbor.event_log.migrate`, and add
`Arbor.Persistence.Ecto.EventStore` to their supervision tree. Application start
and append do not install or repair missing protocol constraints.

Ordinary public event types remain strings. The serializer ignores arbitrary
type hints and returns JSON-clean values, never constructing caller-selected
structs. Schema verification admits valid PostgreSQL qualified/unqualified
trigger renderings only after verifying the actual function/schema/body/flags.

The adapter preserves recovery and fencing behavior but does not declare the
optional `durability_class/1` callback. The generic facade therefore returns
`{:error, :unsupported}` for that capability; successful restart recovery is
not an implicit capability declaration.

Database tests are opt-in and require explicitly provisioned private
`PERSISTENCE_POSTGRES_DB`, `PERSISTENCE_POSTGRES_HOST`,
`PERSISTENCE_POSTGRES_PORT` and `PERSISTENCE_POSTGRES_USER` values. Set
`PERSISTENCE_MIGRATE=1` for test initialization, then include the database lane.
No test selects a live Arbor database by default.
