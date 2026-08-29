import Config

# Common configuration for all Arbor apps
config :logger,
  level: :info

# Allow all custom metadata keys in Logger output.
# Arbor libraries use structured logging with keys like :agent_id, :tool, etc.
config :logger, :default_formatter, metadata: :all

# M7: API key redaction filter installed at runtime by Arbor.Common.Application
# See Arbor.Common.LogRedactor for the filter implementation.

# Comms channels — secrets loaded from .env via runtime.exs
config :arbor_comms, :signal,
  # Off until SIGNAL_FROM / SIGNAL_ACCOUNT is set (see runtime.exs). A fresh
  # install used to spawn `signal-cli -u ''` every 10s, log a warning each
  # time, and journal every failure into SQLite — enough write contention to
  # produce "database is locked" and a Trust.Store timeout during the first
  # `mix arbor.agent start`.
  enabled: false,
  poll_interval_ms: 10_000,
  log_dir: "~/.arbor/logs/signal_chat"

# Limitless pendant channel (inbound only)
config :arbor_comms, :limitless,
  # Off until LIMITLESS_API_KEY is set (see runtime.exs). Unconfigured, the
  # poller raised "LIMITLESS_API_KEY not configured" and crash-looped once a
  # minute on every fresh install.
  enabled: false,
  base_url: "https://api.limitless.ai/v1",
  poll_interval_ms: 60_000,
  log_dir: "~/.arbor/logs/limitless_chat",
  log_retention_days: 30,
  checkpoint_file: "~/.arbor/state/limitless_checkpoint"

# Swoosh: we use SMTP adapter directly, disable the API client
config :swoosh, :api_client, false

# Email channel (outbound only)
config :arbor_comms, :email,
  enabled: true,
  log_dir: "~/.arbor/logs/email_chat",
  log_retention_days: 30

# Comms message handler
# Note: authorized_senders, contact_aliases, and response_recipient
# are set in runtime.exs from SIGNAL_TO env var.
config :arbor_comms, :handler,
  enabled: true,
  response_generator: Arbor.AI.CommsResponder,
  conversation_window: 20,
  dedup_window_seconds: 300

# InteractionRouter: which channel maps to which adapter module.
# Dashboard (Phase 1, 2026-06-04) and Signal (Phase 2, 2026-06-06)
# wired today; Telegram/Discord/voice are additive future entries.
config :arbor_comms, :interaction_adapters, %{
  dashboard: Arbor.Dashboard.InteractionAdapter,
  signal: Arbor.Comms.Channels.Signal.InteractionAdapter
}

# Mandatory engine middleware is enabled by default in every environment. Keep
# this explicit so runtime config drift is visible; set false only as a local
# emergency override while debugging a broken middleware rollout.
config :arbor_orchestrator, mandatory_middleware: true

# Pre-turn preprocessor pipeline. DISABLED by default; fails open when enabled.
# Attaches enrichment to turn context under "session.preprocessor.*".
# See docs/arbor/PREPROCESSOR.md. To enable: set preprocessor_enabled: true (per
# environment) and ensure the configured provider (LM Studio) is reachable with the
# model loaded.
#
# The per-stage model/provider config lives in ONE place — the consolidated defaults
# in `Arbor.Orchestrator.Config.@default_preprocessor` (LM Studio + gemma-4-e4b-it-qat
# for the whole pipeline). Do NOT restate the full config here: a second copy drifts
# from the module default (it did — the old copy pinned Ollama/granite and silently
# shadowed the 2026-06-25 consolidation). Override only specific keys when an
# environment genuinely needs to differ.
config :arbor_orchestrator, preprocessor_enabled: false

# P0-1: Default taint enforcement policy for authorize_and_execute.
# :audit_only logs violations without blocking. Use :strict to block.
config :arbor_actions,
  default_taint_policy: :audit_only,
  coding_default_acp_agent: "codex",
  # Production default: node-restart durable retained-workspace journal is on.
  # config/test.exs must disable this so MIX_ENV=test never opens ~/.arbor.
  workspace_retention_journal_enabled: true

# Channel senders for arbor_actions (runtime resolution, no compile-time dep)
config :arbor_actions, :channel_senders, %{
  signal: Arbor.Comms.Channels.Signal,
  email: Arbor.Comms.Channels.Email
}

# Channel receivers for arbor_actions (runtime resolution, no compile-time dep)
config :arbor_actions, :channel_receivers, %{
  signal: Arbor.Comms.Channels.Signal,
  limitless: Arbor.Comms.Channels.Limitless
}

# Common owner-scoped config lives under :arbor_kernel, :common. Elixir's
# Config reader deep-merges keyword values from imported environment files.
# Runtime injects the optional provider modules. See Arbor.Common.Config.
config :arbor_kernel,
  common: [
    # The tool catalog (a prompt listing of tool names) is OFF: since disclosure
    # became floor ∪ held (2026-08-25) the tool array carries everything callable,
    # and tool_find_tools is a self-describing semantic search over exactly the
    # tools discovery can deliver. The catalog cost ~8 KB of every cached prefix
    # for a section most turns never use. Enable per agent (`tools: :enabled`)
    # or here if a model proves unable to discover by describing the task.
    tool_catalog_enabled: false,
    # Skills follow the Agent Skills pattern: the catalog (name + one-line
    # purpose, ~2.7k tokens for 66 skills) is always in the stable system
    # prompt; bodies (~850 KB total) load on activation. Was dev-only until
    # 2026-08-25, which left every non-dev agent searching a hidden catalog.
    skill_catalog_enabled: true,
    hands: [
      config_dir: "~/.claude-hands",
      sandbox_image: "claude-sandbox",
      sandbox_credentials_volume: "claude-sandbox-credentials"
    ]
  ]

# P0-4: Default workspace for MCP file operations (FileGuard scope)
config :arbor_gateway, mcp_workspace: "~/.arbor/workspace"

# Persistence — Ecto repos for mix tasks (create, migrate, rollback)
# Adapter selected at compile time: SQLite3 (default) or Postgres
# Set ARBOR_DB=postgres to use PostgreSQL (recommended for production)
config :arbor_persistence,
  ecto_repos: [Arbor.Persistence.Repo],
  repo_adapter: Ecto.Adapters.SQLite3

# Database backup with age encryption
# To enable, set enabled: true and create a key pair:
#   age-keygen -o ~/.arbor/backup-key-private.txt
#   age-keygen -y ~/.arbor/backup-key-private.txt > ~/.arbor/backup-key.txt
config :arbor_persistence, :backup,
  enabled: false,
  backup_dir: "~/.arbor/backups",
  age_key_file: "~/.arbor/backup-key.txt",
  schedule: {3, 0},
  retention: [daily: 7, weekly: 4, monthly: 3]

# Signals owner-scoped config lives under :arbor_kernel, :signals.
# Uses runtime configuration to avoid compile-time dependency cycle.
# The checkpoint_store must implement Arbor.Contracts.Persistence.Store behaviour.
# See Arbor.Signals.Config.
config :arbor_kernel,
  signals: [
    checkpoint_module: Arbor.Persistence.Checkpoint,
    checkpoint_store: Arbor.Persistence.Checkpoint.Store.ETS,
    # Signal bus authorization — CapabilityAuthorizer uses fast ETS capability checks
    # via Arbor.Security.can?/3 (runtime bridge, no compile-time dep on arbor_security).
    # Test env overrides to OpenAuthorizer for isolated testing.
    authorizer: Arbor.Signals.Adapters.CapabilityAuthorizer,
    restricted_topics: [:security, :identity],
    # Bootstrap-only subscriptions for load-bearing distributed security state.
    # Signals verifies the caller is the configured registered process and only
    # admits the fixed events listed for that role.
    security_sync_subscribers: %{
      nonce_cache: %{
        owner: Arbor.Security.Identity.NonceCache,
        events: [:nonce_seen]
      },
      capability_store: %{
        owner: Arbor.Security.CapabilityStore,
        events: [
          :capability_granted,
          :capability_revoked,
          :capabilities_revoked_all,
          :capabilities_cascade_revoked,
          :capabilities_scope_revoked
        ]
      },
      identity_registry: %{
        owner: Arbor.Security.Identity.Registry,
        events: [
          :identity_registered,
          :identity_deregistered,
          :identity_suspended,
          :identity_resumed,
          :identity_revoked
        ]
      }
    }
  ]

# ExMCP 1.0.0-rc.6+ defaults to :prefer_modern (MCP 2026-07-28 first). Arbor's
# existing HTTP MCP clients, BEAM agent endpoints, and ACP ToolServer peers
# still speak the legacy initialize handshake. Pin the era explicitly so a
# later ExMCP default change cannot flip production wire behavior.
config :ex_mcp, protocol_mode: :legacy_only

# ACP CLI agents for the multi-model review council (subscription-based, no per-token cost).
# Built-in defaults (Arbor.AI.AcpSession.Config) cover native providers, including the
# security-sensitive Grok command. Overrides REPLACE the per-provider default rather than
# deep-merging, so keep policy-owned native launch commands out of this map.
config :arbor_ai, :acp_providers, %{
  # claude → run Opus (built-in default is sonnet)
  # Adapter pinned to ClaudeSDK (the SDK-protocol-based adapter that talks
  # to Claude Code via the same stream-json control protocol as
  # @anthropic-ai/claude-agent-sdk). See
  # apps/arbor_ai/lib/arbor/ai/acp_session/config.ex for adapter docs.
  claude: %{
    transport_mod: ExMCP.ACP.AdapterTransport,
    adapter: ExMCP.ACP.Adapters.ClaudeSDK,
    adapter_opts: [model: "opus"]
  }

  # antigravity is a built-in native ACP provider using the dedicated
  # `antigravity-acp` executable. RuntimeHome replaces HOME and GEMINI_HOME and
  # projects only an Arbor-owned oauth-personal token. Do not override its
  # policy-owned command here. Optionally select the source outside this map:
  #
  # config :arbor_ai,
  #   antigravity_acp_token_file: "/private/operator/antigravity-acp.json"
}

# AI routing defaults
config :arbor_ai,
  # Default provider/model for API calls (via OpenRouter)
  # gpt-oss-120b:free chosen 2026-06-04 after the previous default
  # (trinity-large-preview:free) was retired April 22. Verified
  # available via OpenRouter's /v1/models listing on update.
  default_provider: :openrouter,
  default_model: "openai/gpt-oss-120b:free",
  timeout: 120_000,
  acp_inactivity_timeout_ms: 300_000,
  enable_task_routing: true,
  default_backend: :api,
  routing_strategy: :cost_optimized,
  tier_routing: %{
    critical: [{:anthropic, :opus}, {:anthropic, :sonnet}],
    complex: [{:anthropic, :sonnet}, {:openai, :gpt5}, {:gemini, :auto}],
    moderate: [{:gemini, :auto}, {:anthropic, :sonnet}, {:openai, :gpt5}],
    simple: [{:opencode, :grok}, {:qwen, :qwen_code}, {:gemini, :auto}],
    trivial: [{:opencode, :grok}, {:qwen, :qwen_code}]
  },
  backend_trust_levels: %{
    lmstudio: :highest,
    ollama: :highest,
    anthropic: :high,
    opencode: :high,
    openai: :medium,
    gemini: :medium,
    qwen: :low,
    openrouter: :low
  },
  # Model-granular data-visibility capabilities for sensitivity routing.
  # Nested format: %{default: [...], models: %{"pattern" => [...]}}
  # Flat list format (legacy) also supported: provider: [:public, :internal]
  backend_capabilities: %{
    ollama: %{
      default: [:public, :internal, :confidential, :restricted],
      models: %{"*:cloud" => [:public, :internal]}
    },
    lmstudio: %{default: [:public, :internal, :confidential, :restricted], models: %{}},
    anthropic: %{default: [:public, :internal, :confidential], models: %{}},
    opencode: %{default: [:public, :internal, :confidential], models: %{}},
    openai: %{default: [:public, :internal], models: %{}},
    gemini: %{default: [:public, :internal], models: %{}},
    openrouter: %{
      default: [:public],
      models: %{
        "anthropic/*" => [:public, :internal, :confidential],
        "google/*" => [:public, :internal]
      }
    },
    qwen: %{default: [:public], models: %{}}
  },
  # Routing candidates for sensitivity-aware auto-selection.
  # Lower priority = preferred. Router picks the lowest-priority candidate
  # that can handle the data sensitivity level.
  routing_candidates: [
    %{provider: :ollama, model: "llama3.2", priority: 1},
    %{provider: :lmstudio, model: "default", priority: 2},
    %{provider: :anthropic, model: "claude-sonnet-4-5-20250514", priority: 3},
    %{provider: :openrouter, model: "anthropic/claude-sonnet-4-5-20250514", priority: 4}
  ],
  embedding_routing: %{
    preferred: :local,
    providers: [
      {:ollama, "nomic-embed-text"},
      {:lmstudio, "text-embedding"},
      {:openai, "text-embedding-3-small"}
    ],
    fallback_to_cloud: true
  },
  # Budget tracking (Phase 2)
  enable_budget_tracking: true,
  daily_api_budget_usd: 10.00,
  budget_prefer_free_threshold: 0.5,
  budget_persistence: false,
  budget_persistence_path: "~/.arbor/budget-tracker.json",
  cost_overrides: %{},
  signal_verbosity: :normal,

  # Sensitivity routing modes are now resolved via trust profiles:
  # Arbor.Trust.effective_mode(agent_id, "arbor://ai/sensitivity") → :block/:ask/:allow/:auto
  # Maps to routing modes: :block→:block, :ask→:gated, :allow→:warn, :auto→:auto
  #
  # Per-agent overrides for sensitivity routing mode.
  # Takes precedence over trust profile resolution.
  sensitivity_routing_overrides: %{},

  # Usage stats tracking (Phase 3)
  enable_stats_tracking: true,
  stats_retention_days: 7,
  stats_persistence: false,
  stats_persistence_path: "~/.arbor/usage-stats.json",
  enable_reliability_routing: false,
  reliability_alert_threshold: 0.8

# Agent autonomy: temporal awareness + cognitive modes + heartbeat loop
config :arbor_agent,
  # Structured task kinds -> TaskExecutor modules (root app wiring only; no
  # arbor_agent -> arbor_orchestrator compile dependency).
  task_executors: %{
    "coding_change" => Arbor.Orchestrator.CodingTaskExecutor
  },
  # Timing context — inject conversational timing into agent prompts
  timing_context_enabled: true,
  timing_format: :human,
  response_urgency_threshold_ms: 120_000,
  # Cognitive mode prompts — specialized framing for background tasks
  cognitive_prompts_enabled: true,
  cognitive_mode_models: %{
    consolidation: "haiku"
  },
  # Heartbeat loop — periodic autonomous processing
  heartbeat_enabled: true,
  heartbeat_interval_ms: 60_000,
  heartbeat_skip_when_busy: true,
  # Message queueing during busy heartbeats
  message_queue_max_size: 100,
  # Context window persistence
  context_persistence_enabled: true,
  context_compression_enabled: true,
  context_window_dir: "~/.arbor/context_windows",
  default_preset: :balanced,
  # Idle reflection — cognitive exploration during quiet time
  idle_reflection_enabled: true,
  idle_reflection_chance: 0.3,
  # LLM heartbeat think cycle (via OpenRouter API)
  # gpt-oss-20b:free chosen 2026-06-04 — smaller/faster than the
  # default_model since heartbeats are short single-shot calls.
  # Verified available via OpenRouter's /v1/models listing on update.
  heartbeat_model: "openai/gpt-oss-20b:free",
  idle_heartbeat_model: "openai/gpt-oss-20b:free",
  heartbeat_provider: :openrouter,
  # Checkpoint — periodic state persistence
  checkpoint_enabled: true,
  checkpoint_interval_ms: 300_000,
  checkpoint_query_threshold: 5,
  checkpoint_store: Arbor.Persistence.Checkpoint.Store.ETS,
  # Context summarization — dual-model approach (Phase 3)
  context_summarization_enabled: true,
  summarizer_model: "claude-haiku",
  summarizer_provider: :anthropic,
  context_max_tokens: 180_000,
  context_min_tokens: 20_000,
  context_recent_ratio: 0.7,
  context_min_recent_messages: 10,
  # Summary tiers
  summary_tiers_enabled: true,
  summary_tier_1_age_hours: 1,
  summary_tier_2_age_hours: 24,
  # Summary cache
  summary_cache_enabled: true,
  summary_cache_ttl_minutes: 60,
  # API agent defaults (tiered config: these are the global tier)
  api_defaults: [
    max_tokens: 16_384,
    temperature: 0.7,
    max_turns: 10
  ],
  # User-editable agent template directory. Files here (`<name>.md`) override
  # the shipped templates baked into the release. `TemplateStore.user_templates_dir/0`
  # expands the leading `~`. Tests override the dir via `set_templates_dir/1`.
  user_templates_dir: "~/.arbor/templates"

# Memory system defaults
config :arbor_memory,
  index_max_entries: 10_000,
  index_default_threshold: 0.3,
  kg_default_decay_rate: 0.10,
  kg_max_nodes_per_type: 500,
  default_model: "anthropic:claude-sonnet-4-5-20250514",
  # Embedding backend: :ets, :pgvector (durable store only), or :dual
  # (ETS + durable store). :dual is the product default so indexed memories
  # survive restart via VectorStore.list rehydration on SQLite or Postgres.
  embedding_backend: :dual,
  # Preconscious (Phase 7): Anticipatory retrieval during heartbeats
  preconscious_enabled: true,
  preconscious_threshold: 0.4,
  preconscious_max_per_check: 3,
  preconscious_lookback_turns: 5,
  # Embedding-based dedup: uses Ollama to catch semantic duplicates in self-knowledge
  # that word-set similarity misses (different vocabulary, same concept)
  embedding_dedup_enabled: false

# Vector store: Ecto on the application Repo. Writes and list/2 work on
# SQLite and Postgres; ANN search still requires pgvector (SQLite recall
# rehydrates ETS and scores in-process).
config :arbor_persistence,
  # Vector dimension: 768 for nomic-embed-text, 1536 for OpenAI
  embedding_dimension: 768,
  vector_store_backend: Arbor.Persistence.VectorStore.Ecto,
  vector_store_repo: Arbor.Persistence.Repo

# Monitor owner-scoped config lives under :arbor_kernel, :monitor.
# Elixir's Config reader deep-merges keyword values from imported
# environment files. Runtime injects the optional provider modules.
# See Arbor.Monitor.Config.
config :arbor_kernel,
  monitor: [
    signal_emission_enabled: true,
    signal_module: Arbor.Signals
  ]

# KernelRuntime owner-scoped config lives under :arbor_kernel, :kernel_runtime.
# Missing or :full starts Common, Signals, and Monitor. :activation_only
# starts none of those nested applications. See Arbor.KernelRuntime.Config.
config :arbor_kernel,
  kernel_runtime: [
    start_profile: :full
  ]

# Full-profile action-namespace projection. Atom only; activation_only must
# not invoke or load this module. arbor_trust must not depend on arbor_actions.
config :arbor_trust, action_profile_provider: Arbor.Actions

# Dashboard chat model configuration
config :arbor_dashboard,
  chat_models: [
    # Anthropic models — use Claude CLI backend (agentic, tool use, thinking)
    %{id: "haiku", label: "Haiku (fast)", provider: :anthropic, backend: :cli},
    %{id: "sonnet", label: "Sonnet (balanced)", provider: :anthropic, backend: :cli},
    %{id: "opus", label: "Opus (powerful)", provider: :anthropic, backend: :cli},
    # OpenRouter models — use API backend
    %{
      id: "openai/gpt-oss-120b:free",
      label: "GPT-OSS 120B (free)",
      provider: :openrouter,
      backend: :api
    },
    %{
      id: "openai/gpt-oss-20b:free",
      label: "GPT-OSS 20B (free, fast)",
      provider: :openrouter,
      backend: :api
    },
    %{id: "openrouter/pony-alpha", label: "Pony Alpha", provider: :openrouter, backend: :api},
    # Z.AI models — use API backend
    %{id: "GLM-4.7", label: "GLM-4.7 (Z.AI)", provider: :zai_coding_plan, backend: :api}
  ],
  # Heartbeat model choices (API models only — CLI models are too slow)
  heartbeat_models: [
    %{
      id: "openai/gpt-oss-20b:free",
      label: "GPT-OSS 20B (free, fast)",
      provider: :openrouter
    },
    %{
      id: "openai/gpt-oss-120b:free",
      label: "GPT-OSS 120B (free)",
      provider: :openrouter
    },
    %{id: "openrouter/pony-alpha", label: "Pony Alpha", provider: :openrouter},
    %{id: "GLM-4.7", label: "GLM-4.7 (Z.AI)", provider: :zai_coding_plan}
  ]

# arbor_scheduler — Oban substrate. Repo lives in arbor_persistence;
# scheduler depends on persistence so this reference is safe.
#
# Nightly reference-pipeline schedule (UTC):
#   06:00 — upstream-deps check  (git fetch + diff report, pure shell)
#   06:15 — upstream-deps summary (LLM categorizes new commits)
#   06:30 — morning digest       (concatenates all overnight reports)
#   06:45 — morning digest synth (LLM produces 'three things worth caring about')
#
# Each LLM step is offset 15 minutes after its data source so slow
# models / cold caches don't race the next stage. Operators add their
# own jobs to the crontab below. Each pipeline is a DOT file under
# `apps/arbor_scheduler/priv/pipelines/`, executed by
# `Arbor.Scheduler.Workers.PipelineRunner` via the orchestrator.
# Legacy version 1 `.caps.json` files fail closed until an operator re-signs
# them as exact version 2 execution attestations with the matching issuer key.
config :arbor_scheduler,
  pipeline_roots: %{
    "scheduler_priv" => Path.expand("../apps/arbor_scheduler/priv/pipelines", __DIR__)
  }

# Follow ARBOR_DB so SQLite boot does not start Oban.Notifiers.Postgres.
{oban_engine, oban_notifier} =
  case System.get_env("ARBOR_DB", "sqlite") do
    "postgres" -> {Oban.Engines.Basic, Oban.Notifiers.Postgres}
    _ -> {Oban.Engines.Lite, Oban.Notifiers.PG}
  end

config :arbor_scheduler, Oban,
  repo: Arbor.Persistence.Repo,
  engine: oban_engine,
  notifier: oban_notifier,
  queues: [default: 10, pipelines: 5, maintenance: 2],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron,
     crontab: [
       {"0 6 * * *", Arbor.Scheduler.Workers.PipelineRunner,
        args: %{
          "pipeline_path" => "apps/arbor_scheduler/priv/pipelines/upstream_deps_check.dot"
        }},
       {"15 6 * * *", Arbor.Scheduler.Workers.PipelineRunner,
        args: %{
          "pipeline_path" => "apps/arbor_scheduler/priv/pipelines/upstream_deps_summary.dot"
        }},
       {"30 6 * * *", Arbor.Scheduler.Workers.PipelineRunner,
        args: %{
          "pipeline_path" => "apps/arbor_scheduler/priv/pipelines/morning_digest.dot"
        }},
       {"45 6 * * *", Arbor.Scheduler.Workers.PipelineRunner,
        args: %{
          "pipeline_path" => "apps/arbor_scheduler/priv/pipelines/morning_digest_synthesis.dot"
        }}
     ]}
  ]

# Dashboard endpoint
config :arbor_dashboard, Arbor.Dashboard.Endpoint,
  url: [host: "localhost"],
  pubsub_server: Arbor.Dashboard.PubSub,
  # Without an explicit render_errors view, Phoenix derives one from the
  # endpoint's top namespace -> Arbor.ErrorView, which does not exist. Any
  # request that raised (404/500) then crashed the render-errors path itself
  # with `no "500" html template defined for Arbor.ErrorView`, masking the
  # original exception. Point at real, minimal error views instead.
  render_errors: [
    formats: [html: Arbor.Dashboard.ErrorHTML, json: Arbor.Dashboard.ErrorJSON],
    layout: false
  ],
  live_view: [signing_salt: "arbor_dashboard_lv"]

# ── Egress gate (2026-06-14 URI-addressing-vs-classification decision) ───────
#
# The egress gate classifies outbound operations (LLM/web/comms/ACP) by tier
# (on_host / on_premises / external_provider / external_peer) and can gate them.
# It is DARK by default — classification + :egress_observed telemetry run, but
# nothing is blocked or asked. See `.arbor/decisions/2026-06-14-uri-addressing-
# vs-security-classification.md`.
#
# To ENABLE (do this AFTER observing real :egress_observed telemetry — see the
# runbook in the decision doc; flipping blind can halt cloud heartbeats that
# carry untrusted data):
#
#   config :arbor_security, egress_gate_enforcing: true
#   # single-operator default posture so normal cloud egress isn't gated — the
#   # taint-exfil block (untrusted data -> external) + per-agent :block/:ask
#   # tightening still apply:
#   config :arbor_trust, default_egress_modes: %{external_provider: :allow}
#   # optionally gate homelab/LAN egress too (default off):
#   # config :arbor_security, gate_on_premises_egress: true

# Import environment-specific config
# LLM provider fallback for reviewed graphs (council seats pin a preferred
# provider per node). When this host cannot call the preferred provider, the
# LLM handler takes the first available candidate below and the verdict names
# it. Order matters; add your own providers/models here.
# Baseline image step backends (B2a). Selected from the validation runtime's
# reported driver; paths are reviewed host config, not literals in code.
config :arbor_commands,
  baseline_image_executables: %{
    "podman" => "/usr/bin/podman",
    "apple_container" => "/usr/local/bin/container"
  }

# Advisory council: resolve each seat's preferred route against this host
# (same rule as the binding council) through the arbor_llm route probe.
config :arbor_consensus,
  provider_route_mfa: {Arbor.LLM, :provider_route},
  advisory_provider_fallbacks: %{}

config :arbor_orchestrator,
  llm_fallback_providers: [
    {"openai_oauth", "gpt-5.6-sol"},
    {"xai_oauth", "grok-4.6"}
  ],
  llm_provider_fallbacks: %{}

import_config "#{config_env()}.exs"
