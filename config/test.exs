import Config

config :logger, level: :warning

# Don't start HTTP server in tests
config :arbor_gateway, start_server: false

# Disable checkpoint integration in tests (module may not be available)
config :arbor_signals,
  checkpoint_module: nil,
  checkpoint_store: nil

# Postgres tests require a database
# Run: mix ecto.create -r Arbor.Persistence.Repo
# Run: mix ecto.migrate -r Arbor.Persistence.Repo
# Then: mix test --include database
# Don't start Signal poller or message handler in tests
config :arbor_comms, :signal, enabled: false
config :arbor_comms, :limitless, enabled: false
config :arbor_comms, :email, enabled: false
config :arbor_comms, :handler, enabled: false

config :arbor_persistence, Arbor.Persistence.Repo,
  database: "arbor_persistence_test",
  username: "arbor_dev",
  hostname: "localhost",
  pool: Ecto.Adapters.SQL.Sandbox

# Memory tests use ETS by default (no database required)
config :arbor_memory,
  embedding_backend: :ets

# pgvector tests (requires postgres + pgvector extension)
config :arbor_persistence,
  embedding_dimension: 384
