import Config

config :logger, level: :warning

# Don't start HTTP server in tests
config :arbor_gateway, start_server: false

# Don't start application supervision trees in tests —
# tests use start_supervised! for what they need
config :arbor_signals, start_children: false
config :arbor_trust, start_children: false

config :arbor_security,
  start_children: false,
  # Disable file persistence in tests — everything in-memory only
  storage_backend: nil,
  # Tests that bypass Security.grant/1 create unsigned capabilities.
  # Only the grant facade signs via SystemAuthority — direct CapabilityStore.put
  # stores unsigned caps. Require signing in prod, not in tests.
  capability_signing_required: false,
  # Disable identity verification by default in tests — most tests don't have
  # crypto infrastructure. Tests that specifically test identity verification
  # opt in with verify_identity: true.
  identity_verification: false,
  # P0-3: Permissive identity mode in tests — most tests don't register identities.
  # Production uses strict mode (unknown identities rejected).
  strict_identity_mode: false,
  # Disable reflex checking in tests — reflex infrastructure (ETS tables, GenServers)
  # isn't started when start_children: false. Without this, authorize/4 fails closed
  # with {:reflex_check_failed, :exception} on every call.
  reflex_checking_enabled: false

config :arbor_persistence, start_children: false
config :arbor_ai, start_children: false
config :arbor_consensus, start_children: false
config :arbor_memory, start_children: false
config :arbor_shell, start_children: false
config :arbor_sandbox, start_children: false
config :arbor_agent, start_children: false
config :arbor_sdlc, start_children: false
config :arbor_historian, start_children: false
config :arbor_dashboard, start_children: false
config :arbor_demo, start_children: false

config :arbor_monitor,
  start_children: false,
  signal_emission_enabled: false,
  suppression_window_ms: :timer.seconds(5)

# Don't start the dashboard HTTP server in tests
config :arbor_dashboard, Arbor.Dashboard.Endpoint,
  http: [port: 4002],
  server: false,
  secret_key_base: String.duplicate("test_secret_", 8)

# Disable checkpoint integration in tests (module may not be available).
# Use OpenAuthorizer — tests don't have the security kernel running.
config :arbor_signals,
  checkpoint_module: nil,
  checkpoint_store: nil,
  authorizer: Arbor.Signals.Adapters.OpenAuthorizer,
  allow_open_authorizer: true

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
  pool: Ecto.Adapters.SQL.Sandbox,
  types: Arbor.Persistence.PostgrexTypes

# Memory tests use ETS by default (no database required)
config :arbor_memory,
  embedding_backend: :ets,
  persistence_backend: nil

# pgvector tests (requires postgres + pgvector extension)
config :arbor_persistence,
  embedding_dimension: 768

# P0-1: Keep permissive taint in tests — existing tests don't set taint context
config :arbor_actions, default_taint_policy: :permissive

# Use hash-based test embeddings when no real providers are available
config :arbor_ai, embedding_test_fallback: true

# Don't probe local LLM servers (LM Studio, Ollama) during tests
config :arbor_orchestrator, discover_local_providers: false

# Enable mandatory middleware (Phase 5 handler primitives)
config :arbor_orchestrator, mandatory_middleware: true
