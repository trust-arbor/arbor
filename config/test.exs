import Config

# Load .env at compile time so ARBOR_DB is available for adapter selection
dotenv_path = Path.join(__DIR__, "../.env")

if File.exists?(dotenv_path) do
  dotenv_path
  |> File.read!()
  |> String.split("\n", trim: true)
  |> Enum.reject(&(String.starts_with?(&1, "#") or &1 == ""))
  |> Enum.each(fn line ->
    case String.split(line, "=", parts: 2) do
      [key, value] ->
        key = key |> String.trim() |> String.replace_leading("export ", "")
        value = value |> String.trim() |> String.trim("\"") |> String.trim("'")
        unless System.get_env(key), do: System.put_env(key, value)

      _ ->
        :skip
    end
  end)
end

config :logger, level: :warning

# Don't start HTTP server or MCP client supervisor in tests
config :arbor_gateway, start_server: false, mcp_client_enabled: false

# Don't start application supervision trees in tests —
# tests use start_supervised! for what they need
config :arbor_signals, start_children: false
config :arbor_trust, start_children: false

config :arbor_security,
  start_children: false,
  # Disable file persistence in tests — everything in-memory only
  storage_backend: nil,
  # Tests that bypass Security.grant/1 create unsigned capabilities.
  capability_signing_required: false,
  # Most tests don't have crypto infrastructure.
  identity_verification: false,
  # Most tests don't register identities.
  strict_identity_mode: false,
  # Reflex infrastructure not started when start_children: false.
  reflex_checking_enabled: false,
  # PolicyEnforcer needs Trust system running — disable in tests.
  # Tests that need it opt in explicitly.
  policy_enforcer_enabled: false,
  # ApprovalGuard needs Consensus + Trust — disable in tests.
  approval_guard_enabled: false,
  # URI registry enforcement needs the GenServer running.
  uri_registry_enforcement: false,
  # Use ephemeral keypair in tests — no persistence side effects
  system_authority_mode: :ephemeral

config :arbor_common, start_children: false
config :arbor_persistence, start_children: false
config :arbor_ai, start_children: false
config :arbor_consensus, start_children: false
config :arbor_memory, start_children: false
config :arbor_shell, start_children: false
config :arbor_sandbox, start_children: false

config :arbor_agent,
  start_children: false,
  profile_storage_backend: nil,
  bootstrap_enabled: false

config :arbor_historian, start_children: false
config :arbor_dashboard, start_children: false

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

# Database tests require a database
# Run: mix ecto.create -r Arbor.Persistence.Repo
# Run: mix ecto.migrate -r Arbor.Persistence.Repo
# Then: mix test --include database
# Don't start Signal poller or message handler in tests
config :arbor_comms, :signal, enabled: false
config :arbor_comms, :limitless, enabled: false
config :arbor_comms, :email, enabled: false
config :arbor_comms, :handler, enabled: false

# Test database — adapter-aware
# Note: The Ecto SQLite3 adapter does not support async tests
# when used with Ecto.Adapters.SQL.Sandbox
if System.get_env("ARBOR_DB") == "postgres" do
  config :arbor_persistence,
    repo_adapter: Ecto.Adapters.Postgres

  config :arbor_persistence, Arbor.Persistence.Repo,
    database: "arbor_persistence_test",
    username: "arbor_dev",
    hostname: "localhost",
    pool: Ecto.Adapters.SQL.Sandbox,
    types: Arbor.Persistence.PostgrexTypes
else
  config :arbor_persistence,
    repo_adapter: Ecto.Adapters.SQLite3

  config :arbor_persistence, Arbor.Persistence.Repo,
    database: Path.expand("~/.arbor/arbor_test.db"),
    pool: Ecto.Adapters.SQL.Sandbox,
    busy_timeout: 5_000,
    journal_mode: :wal
end

# Memory tests use ETS by default (no database required)
config :arbor_memory,
  embedding_backend: :ets,
  persistence_backend: nil,
  auto_embed: false

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
