import Config

config :logger, level: :debug

# Persistence — PostgreSQL for durable storage
config :arbor_persistence, Arbor.Persistence.Repo,
  database: "arbor_persistence_dev",
  username: "arbor_dev",
  hostname: "localhost",
  pool_size: 10,
  log: false,
  types: Arbor.Persistence.PostgrexTypes

config :arbor_persistence,
  start_repo: true,
  # No ETS stores needed — Postgres backends are stateless
  stores: []

# Dashboard — local dev server on port 4001
# LiveView debug annotations for Tidewave AI integration
config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true

config :arbor_dashboard, Arbor.Dashboard.Endpoint,
  http: [port: 4001],
  secret_key_base: String.duplicate("arbor_dashboard_dev_secret_", 4),
  debug_errors: true,
  code_reloader: false,
  check_origin: false,
  server: true

# Memory — Postgres backend for durable memory persistence
config :arbor_memory,
  persistence_backend: Arbor.Persistence.QueryableStore.Postgres

# Actions — use Postgres backends for durable job tracking
config :arbor_actions, :persistence,
  queryable_store_backend: Arbor.Persistence.QueryableStore.Postgres,
  event_log_backend: Arbor.Persistence.EventLog.Postgres

# Security — disable identity verification in dev until agents wire signed requests
# into query/heartbeat paths. Without this, authorize/4 rejects all tool calls
# with :missing_signed_request, filtering out every tool.
config :arbor_security, identity_verification: false

# Signals — allow OpenAuthorizer in dev (production requires CapabilityAuthorizer)
config :arbor_signals, allow_open_authorizer: true

# Monitor — short suppression window for demo (30 seconds instead of 30 minutes)
config :arbor_monitor, suppression_window_ms: :timer.seconds(30)

# Gateway — dev API key for local MCP access
config :arbor_gateway, api_key: "arbor-dev-key"
