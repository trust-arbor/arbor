import Config

config :logger, level: :debug

# Persistence — PostgreSQL for durable storage
config :arbor_persistence, Arbor.Persistence.Repo,
  database: "arbor_persistence_dev",
  username: "arbor_dev",
  hostname: "localhost",
  pool_size: 10,
  log: false

config :arbor_persistence,
  start_repo: true,
  # No ETS stores needed — Postgres backends are stateless
  stores: []

# Dashboard — local dev server on port 4001
config :arbor_dashboard, Arbor.Dashboard.Endpoint,
  http: [port: 4001],
  secret_key_base: String.duplicate("arbor_dashboard_dev_secret_", 4),
  debug_errors: true,
  code_reloader: false,
  check_origin: false,
  server: true

# Actions — use Postgres backends for durable job tracking
config :arbor_actions, :persistence,
  queryable_store_backend: Arbor.Persistence.QueryableStore.Postgres,
  event_log_backend: Arbor.Persistence.EventLog.Postgres
