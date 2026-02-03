import Config

# Common configuration for all Arbor apps
config :logger,
  level: :info

# Allow all custom metadata keys in Logger output.
# Arbor libraries use structured logging with keys like :agent_id, :tool, etc.
config :logger, :default_formatter, metadata: :all

# Comms channels — secrets loaded from .env via runtime.exs
config :arbor_comms, :signal,
  enabled: true,
  poll_interval_ms: 10_000,
  log_dir: "~/.arbor/logs/signal_chat"

# Limitless pendant channel (inbound only)
config :arbor_comms, :limitless,
  enabled: true,
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

# Hands — independent Claude Code sessions for delegated work
config :arbor_common, :hands,
  config_dir: "~/.claude-hands",
  sandbox_image: "claude-sandbox",
  sandbox_credentials_volume: "claude-sandbox-credentials"

# Persistence — Ecto repos for mix tasks (create, migrate, rollback)
config :arbor_persistence,
  ecto_repos: [Arbor.Persistence.Repo]

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

# Signal store checkpoint integration
# Uses runtime configuration to avoid compile-time dependency cycle.
# The checkpoint_store must implement Arbor.Checkpoint.Store behaviour.
config :arbor_signals,
  checkpoint_module: Arbor.Checkpoint,
  checkpoint_store: Arbor.Checkpoint.Store.ETS,
  # Signal bus authorization — OpenAuthorizer allows all (backward compatible).
  # Switch to SecurityAuthorizer when the security kernel is running.
  authorizer: Arbor.Signals.Adapters.OpenAuthorizer,
  restricted_topics: [:security, :identity]

# AI routing defaults
config :arbor_ai,
  enable_task_routing: true,
  default_backend: :auto,
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

  # Usage stats tracking (Phase 3)
  enable_stats_tracking: true,
  stats_retention_days: 7,
  stats_persistence: false,
  stats_persistence_path: "~/.arbor/usage-stats.json",
  enable_reliability_routing: false,
  reliability_alert_threshold: 0.8

# Memory system defaults
config :arbor_memory,
  index_max_entries: 10_000,
  index_default_threshold: 0.3,
  kg_default_decay_rate: 0.10,
  kg_max_nodes_per_type: 500,
  default_model: "anthropic:claude-sonnet-4-5-20250514",
  # Embedding backend: :ets (default), :pgvector, or :dual (ETS + pgvector)
  embedding_backend: :ets,
  # Preconscious (Phase 7): Anticipatory retrieval during heartbeats
  preconscious_enabled: true,
  preconscious_threshold: 0.4,
  preconscious_max_per_check: 3,
  preconscious_lookback_turns: 5

# pgvector embedding configuration
config :arbor_persistence,
  # Vector dimension: 768 for nomic-embed-text, 1536 for OpenAI
  embedding_dimension: 768

# Dashboard endpoint
config :arbor_dashboard, Arbor.Dashboard.Endpoint,
  url: [host: "localhost"],
  pubsub_server: Arbor.Dashboard.PubSub,
  live_view: [signing_salt: "arbor_dashboard_lv"]

# Import environment-specific config
import_config "#{config_env()}.exs"
