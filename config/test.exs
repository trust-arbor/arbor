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
  # Egress gate stays DARK in tests — the egress gate tests toggle enforcing
  # per-test via Application.put_env. Explicit here so a future base-config
  # change can't silently enforce egress across the whole suite.
  egress_gate_enforcing: false,
  # Use ephemeral keypair in tests — no persistence side effects
  system_authority_mode: :ephemeral

config :arbor_common, start_children: false
config :arbor_persistence, start_children: false
config :arbor_ai, start_children: false

# Default LLM provider and model for :llm tagged tests.
# Uses a free model to avoid costs in CI. Individual tests can override.
# Set UNIFIED_LLM_DEFAULT_PROVIDER / UNIFIED_LLM_DEFAULT_MODEL env vars to change.
config :arbor_ai,
  default_provider:
    (System.get_env("UNIFIED_LLM_DEFAULT_PROVIDER") || "openrouter") |> String.to_atom(),
  default_model: System.get_env("UNIFIED_LLM_DEFAULT_MODEL") || "openai/gpt-oss-120b:free"

# Hermetic default provider NAME for the gating lane. This is a name only —
# no api_key, no base_url — so `Arbor.LLM.Client.from_env/1` can CONSTRUCT a
# client when UNIFIED_LLM_DEFAULT_PROVIDER is unset. Tests that mock the LLM
# dispatch then run without any network. Tests that make a real call are
# tagged :llm and run in the non-gating LLM lane.
config :arbor_llm,
  default_provider: System.get_env("UNIFIED_LLM_DEFAULT_PROVIDER") || "openrouter"

config :arbor_consensus, start_children: false
config :arbor_memory, start_children: false
config :arbor_shell, start_children: false
config :arbor_sandbox, start_children: false

# ---------------------------------------------------------------------------
# Centralize path-specific LLM model config on UNIFIED_LLM_DEFAULT_MODEL.
#
# The non-gating :llm lane points UNIFIED_LLM_DEFAULT_MODEL at a local Ollama
# model (e.g. gemma4:e4b). Only :arbor_ai default_model honored that env var
# previously; these path-specific keys stayed hardcoded to OpenRouter/Anthropic
# models (and providers) and thus 404'd against the local Ollama backend.
#
# When UNIFIED_LLM_DEFAULT_MODEL is set we override each model AND its provider
# to a plain Ollama model id / :ollama. When it is unset, every fallback is the
# CURRENT config.exs value, so the gating/dev lane behavior is unchanged.
unified_llm_model = System.get_env("UNIFIED_LLM_DEFAULT_MODEL")

# arbor_agent: heartbeat + idle-heartbeat + context summarizer.
# Providers MUST also flip to :ollama — Arbor.Agent.LLMDefaults / ContextSummarizer
# resolve heartbeat_provider/summarizer_provider from these keys first, so leaving
# them at :openrouter/:anthropic would route the Ollama model id to the wrong host.
config :arbor_agent,
  start_children: false,
  profile_storage_backend: nil,
  bootstrap_enabled: false,
  heartbeat_model: unified_llm_model || "openai/gpt-oss-20b:free",
  idle_heartbeat_model: unified_llm_model || "openai/gpt-oss-20b:free",
  heartbeat_provider: if(unified_llm_model, do: :ollama, else: :openrouter),
  summarizer_model: unified_llm_model || "claude-haiku",
  summarizer_provider: if(unified_llm_model, do: :ollama, else: :anthropic)

# arbor_memory: default_model. NOTE: no code path currently reads
# :arbor_memory/:default_model (verified — it is inert today), but we override it
# from the env var for consistency so any future reader resolves to the local
# Ollama model. Fallback is the current config.exs value.
config :arbor_memory,
  default_model: unified_llm_model || "anthropic:claude-sonnet-4-5-20250514"

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
  auto_embed: false,
  # Don't reach the live Arbor.AI embedding backend (Ollama) in the hermetic test
  # lane (see embedding_service_available? in knowledge_graph[/graph_search] +
  # context_window/compression). Tests use synthetic embeddings via
  # Embedding.store/search; the live embed path is :llm-lane territory. Reaching
  # Ollama here caused flaky Finch pool-exhaustion timeouts (KnowledgeGraphTest).
  embedding_service_enabled: false

# pgvector tests (requires postgres + pgvector extension)
config :arbor_persistence,
  embedding_dimension: 768

# P0-1: Keep permissive taint in tests — existing tests don't set taint context
config :arbor_actions, default_taint_policy: :permissive

# Use hash-based test embeddings when no real providers are available
config :arbor_ai, embedding_test_fallback: true

# Don't probe local LLM servers (LM Studio, Ollama) during tests by
# default. But when ARBOR_OLLAMA_BASE_URL is set (homelab / CI with a
# reachable Ollama), enable discovery so :llm-tagged tests that route at
# `provider: :ollama` actually reach the server instead of falling back
# to the non-LLM path. runtime.exs points the ollama base_url at that
# endpoint; the HTTP probe in Client.from_env then registers the adapter.
config :arbor_orchestrator,
  discover_local_providers: System.get_env("ARBOR_OLLAMA_BASE_URL") not in [nil, ""]

# Don't run the model-availability preflight at startup during tests (it would
# poke LM Studio / Ollama). The Preflight module is still unit-tested directly.
config :arbor_orchestrator, preflight_models_on_start: false

# Keep mandatory middleware explicit in tests; Chain also defaults this on when
# the env key is absent.
config :arbor_orchestrator, mandatory_middleware: true

# arbor_scheduler — disable real Oban supervision in tests. Tests use
# Oban.Testing to assert enqueueing without touching the DB or running
# workers; tests that need a live Oban supervisor start their own.
config :arbor_scheduler, start_children: false

config :arbor_scheduler, Oban,
  repo: Arbor.Persistence.Repo,
  testing: :manual,
  queues: false,
  plugins: false
