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
        key = key |> String.trim() |> String.replace_leading("export ", "")
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
    database: Path.expand("~/.arbor/arbor_dev.db"),
    busy_timeout: 5_000,
    journal_mode: :wal,
    cache_size: -64_000,
    temp_store: :memory

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
      # Matches default_model in config.exs:165 — keep in sync if changing.
      id: "openai/gpt-oss-120b:free",
      provider: :openrouter,
      backend: :api
    },
    start_host: true
  }
]

# Security — all features enabled in dev.
# Tests disable what they need; dev should match prod behavior.
config :arbor_security,
  identity_verification: true,
  capability_signing_required: true,
  # M3 review fix (2026-06-09): match prod (prod.exs already sets this).
  # Without it, identity-registry unavailability / unknown-principal fails
  # OPEN in dev — and the agent host runs dev. Verified safe before flipping:
  # on the running server, unregistered string principals (e.g. "system")
  # are already denied for lack of capabilities, and every working flow uses
  # a registered crypto agent (status :active), so strict mode changes the
  # denial *reason* for unregistered principals, not the outcome.
  strict_identity_mode: true,
  policy_enforcer_enabled: true,
  approval_guard_enabled: true,
  uri_registry_enforcement: true,
  consensus_escalation_enabled: true,
  # HITL Router Phase 1b validation: route approvals via InteractionRouter
  # rather than the legacy ConsensusManager.escalate path. The router targets
  # the dashboard (ChatLive's approvals panel) and falls back to "queued"
  # when no channel is reachable, so the agent still gets a non-blocking
  # request_id back.
  use_interaction_router_for_approval: true,
  session_token_secret: "arbor-dev-session-token-secret-change-in-prod"

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

# ACP Pool — allow more concurrent Claude CLI sessions in dev
config :arbor_ai, :acp_pool_config,
  default_max: 10,
  providers: %{
    claude: %{max: 10, idle_timeout_ms: 300_000},
    gemini: %{max: 3, idle_timeout_ms: 300_000}
  }

# Egress gate — ENABLED (2026-06-14, after dark observation + live validation).
# See `.arbor/decisions/2026-06-14-uri-addressing-vs-security-classification.md`.
# Live data: normal agent egress = external_provider / taint=nil; idle heartbeats
# don't egress. Default-allow posture lets normal cloud egress flow — the
# always-on taint conjunct (untrusted/hostile -> external = block) and per-agent
# egress_modes (:block/:ask) are the active protections.
config :arbor_security, egress_gate_enforcing: true
config :arbor_trust, default_egress_modes: %{external_provider: :allow}
# To also gate homelab/LAN egress: config :arbor_security, gate_on_premises_egress: true
