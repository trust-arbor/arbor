import Config

config :logger, level: :warning

# Don't start HTTP server in tests
config :arbor_gateway, start_server: false

# Postgres tests require a database
# Run: mix ecto.create -r Arbor.Persistence.Repo
# Run: mix ecto.migrate -r Arbor.Persistence.Repo
# Then: mix test --include postgres
# Don't start Signal poller or message handler in tests
config :arbor_comms, :signal, enabled: false
config :arbor_comms, :limitless, enabled: false
config :arbor_comms, :email, enabled: false
config :arbor_comms, :handler, enabled: false

config :arbor_persistence, Arbor.Persistence.Repo,
  database: "arbor_test",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  pool: Ecto.Adapters.SQL.Sandbox
