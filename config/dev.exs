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

# Agent — auto-start infrastructure agents on boot.
#
# DISABLED 2026-06-22: the at-boot diagnostician seed was broken — its identity
# never registered in Arbor.Agent.Registry (so `find_agent`/`stop_agent` can't
# see it), yet its orphaned BranchSupervisor heartbeat kept firing the
# `arbor://orchestrator/execute` authorization gate every ~30s. Each beat
# escalated via the InteractionRouter, flooding the operator's Signal with
# thousands of orphaned approval requests. The trust profile is NOT the lever
# (effective_mode :auto / :veteran tier did not stop it — the break is the
# bootstrap path, not trust).
#
# Re-enable only after migrating the diagnostician to the STANDARD agent
# lifecycle (Lifecycle.create/start + auto_start flag on its persisted profile)
# instead of this at-boot seed, so it gets a registered identity + a real trust
# profile like every other agent. Tracked in
# `.arbor/roadmap/0-inbox/diagnostician-bootstrap-migration.md`.
config :arbor_agent, :auto_start_agents, []

# Original seed, preserved for the migration:
#   %{
#     display_name: "diagnostician",
#     module: Arbor.Agent.APIAgent,
#     template: "diagnostician",
#     model_config: %{
#       id: "openai/gpt-oss-120b:free",
#       provider: :openrouter,
#       backend: :api
#     },
#     start_host: true
#   }

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

# SpawnWorker capability intersection fails CLOSED by default — if a parent's permissions
# can't be established (no trust profile / trust unavailable / error), a spawned worker is
# DENIED rather than granted everything requested (it must never exceed the parent). Accept
# the risk (e.g. profile-less dev agents) by opting into the old fail-OPEN behavior:
# config :arbor_actions, spawn_worker_fail_open: true

# Worker default model — workers run bounded sub-tasks and must not sit on the rate-limited
# gpt-oss-120b:free tier (429 → empty worker report). Point them at a reliable subscription
# model, independent of the global agent default.
config :arbor_actions, worker_default_provider: :ollama
config :arbor_actions, worker_default_model: "kimi-k2.7-code:cloud"

# Slow LOCAL coordinators orchestrating nested workers exceed the 5-min default turn timeout
# (gemma-4-31b timed out). 15 min gives agentic local turns room; still a safety net.
config :arbor_orchestrator, turn_timeout_ms: 900_000

# Structured coding tasks accept repository input only within this explicit
# root. `runtime.exs` creates a project-scoped temporary worktree root in dev,
# keeping generated worktrees outside this checkout. Prod deliberately has no
# implicit root configuration.
arbor_source_root = Path.expand("..", __DIR__)

config :arbor_orchestrator, coding_repo_roots: [arbor_source_root]

# Auto-load AGENTS.md/CLAUDE.md into agent system prompts (Claude-Code-style). Off by default
# (changes every agent's prompt); on in dev so agents know Arbor's conventions. Read by both the
# APIAgent stable-prompt path (Arbor.AI.SystemPromptBuilder) and the DOT-pipeline path (LlmHandler).
config :arbor_common, project_context_enabled: true

# Surface a compact catalog of available skills (name + description) in the stable prompt so
# agents know WHAT skills exist (progressive disclosure; bodies load on activate). Off by default;
# on in dev. Per-agent Config.skills (:enabled/:disabled) overrides this; :inherit uses it.
config :arbor_common, skill_catalog_enabled: true

# Pre-turn preprocessor ON in dev (consolidated 2026-06-25 onto LM Studio +
# gemma-4-e4b-it-qat for the whole pipeline). Requires the model loaded in LM
# Studio at localhost:1234. Fails open if unreachable. prod stays off (config.exs)
# until a deliberate enable; test stays off to keep the suite fast. Per-stage
# model/provider lives in Arbor.Orchestrator.Config.@default_preprocessor — don't
# restate it here, only override specific keys if dev needs to differ.
config :arbor_orchestrator, preprocessor_enabled: true
