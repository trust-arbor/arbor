import Config

config :logger, level: :warning

# Don't start HTTP server in tests
config :arbor_bridge, start_server: false

# Postgres tests require a database
# Run: mix ecto.create -r Arbor.Persistence.Repo
# Run: mix ecto.migrate -r Arbor.Persistence.Repo
# Then: mix test --include postgres
config :arbor_persistence, Arbor.Persistence.Repo,
  database: "arbor_test",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  pool: Ecto.Adapters.SQL.Sandbox
