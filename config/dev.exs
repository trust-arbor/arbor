import Config

config :logger, level: :debug

# Load .env at compile time so ARBOR_DB is available for adapter selection.
# runtime.exs also loads .env, but compile-time config runs first.
dotenv_path = Path.join(__DIR__, "../.env")

if File.exists?(dotenv_path) do
  dotenv_path
  |> File.read!()
  |> String.split("\n", trim: true)
  |> Enum.reject(&(String.starts_with?(&1, "#") or &1 == ""))
  |> Enum.each(fn line ->
    case String.split(line, "=", parts: 2) do
      [key, value] ->
        key = String.trim(key)
        value = value |> String.trim() |> String.trim("\"") |> String.trim("'")
        # Only set if not already in environment (env vars take precedence)
        unless System.get_env(key), do: System.put_env(key, value)

      _ ->
        :skip
    end
  end)
end

# Persistence — adapter selected by ARBOR_DB env var
# Default: SQLite (zero-config). Set ARBOR_DB=postgres for PostgreSQL.
if System.get_env("ARBOR_DB") == "postgres" do
  # PostgreSQL
  config :arbor_persistence, Arbor.Persistence.Repo,
    database: "arbor_persistence_dev",
    username: System.get_env("DB_USER", "arbor_dev"),
    password: System.get_env("DB_PASS", ""),
    hostname: "localhost",
    pool_size: 10,
    log: false,
    types: Arbor.Persistence.PostgrexTypes

  config :arbor_persistence,
    repo_adapter: Ecto.Adapters.Postgres,
    start_repo: true,
    stores: []

  config :arbor_memory,
    persistence_backend: Arbor.Persistence.QueryableStore.Postgres,
    embedding_dedup_enabled: true
else
  # SQLite — zero-config default
  config :arbor_persistence,
    repo_adapter: Ecto.Adapters.SQLite3,
    start_repo: true,
    stores: []

  config :arbor_persistence, Arbor.Persistence.Repo,
    database: Path.expand("~/.arbor/arbor_dev.db")

  config :arbor_memory,
    persistence_backend: Arbor.Persistence.QueryableStore.Postgres,
    embedding_backend: :ets,
    embedding_dedup_enabled: false
end

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

# Actions — use Postgres backends for durable job tracking (both adapters use the same Ecto queries)
config :arbor_actions, :persistence,
  queryable_store_backend: Arbor.Persistence.QueryableStore.Postgres,
  event_log_backend: Arbor.Persistence.EventLog.Postgres

# Agent — auto-start infrastructure agents on boot
config :arbor_agent, :auto_start_agents, [
  %{
    display_name: "diagnostician",
    module: Arbor.Agent.APIAgent,
    template: "diagnostician",
    model_config: %{
      id: "arcee-ai/trinity-large-preview:free",
      provider: :openrouter,
      backend: :api
    },
    start_host: true
  }
]

# Security — identity verification and capability signing enabled.
# Session tool dispatch now wires signed requests via Lifecycle.build_signer.
config :arbor_security,
  identity_verification: true,
  capability_signing_required: true

# OIDC — Human identity authentication for CLI and orchestration.
# Uncomment and configure for your OIDC provider (Zitadel, Google, GitHub, etc.)
# config :arbor_security, :oidc,
#   device_flow: %{
#     issuer: "https://your-provider.example.com",
#     client_id: "your-client-id",
#     scopes: ["openid", "email", "profile"]
#   },
#   providers: [
#     %{
#       issuer: "https://your-provider.example.com",
#       client_id: "your-client-id",
#       client_secret: "your-client-secret",
#       scopes: ["openid", "email", "profile"]
#     }
#   ]

# Signals — allow OpenAuthorizer in dev (production requires CapabilityAuthorizer)
config :arbor_signals, allow_open_authorizer: true

# Monitor — short suppression window for demo (30 seconds instead of 30 minutes)
config :arbor_monitor, suppression_window_ms: :timer.seconds(30)

# Gateway — dev API key for local MCP access
config :arbor_gateway, api_key: "arbor-dev-key"
