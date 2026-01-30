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
  log_dir: "/tmp/arbor/signal_chat"

# Limitless pendant channel (inbound only)
config :arbor_comms, :limitless,
  enabled: true,
  base_url: "https://api.limitless.ai/v1",
  poll_interval_ms: 60_000,
  log_dir: "/tmp/arbor/limitless_chat",
  log_retention_days: 30,
  checkpoint_file: "/tmp/arbor/limitless_checkpoint"

# Swoosh: we use SMTP adapter directly, disable the API client
config :swoosh, :api_client, false

# Email channel (outbound only)
config :arbor_comms, :email,
  enabled: true,
  log_dir: "/tmp/arbor/email_chat",
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

# Import environment-specific config
import_config "#{config_env()}.exs"
