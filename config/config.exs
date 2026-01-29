import Config

# Common configuration for all Arbor apps
config :logger,
  level: :info

# Allow all custom metadata keys in Logger output.
# Arbor libraries use structured logging with keys like :agent_id, :tool, etc.
config :logger, :default_formatter, metadata: :all

# Comms channels - disabled by default, enable per-environment
config :arbor_comms, :signal,
  enabled: true,
  account: System.get_env("SIGNAL_ACCOUNT"),
  signal_cli_path: System.get_env("SIGNAL_CLI_PATH"),
  poll_interval_ms: 60_000,
  log_dir: "/tmp/arbor/signal_chat"

# Limitless pendant channel (inbound only)
config :arbor_comms, :limitless,
  enabled: true,
  api_key: System.get_env("LIMITLESS_API_KEY"),
  base_url: "https://api.limitless.ai/v1",
  poll_interval_ms: 300_000,
  log_dir: "/tmp/arbor/limitless_chat",
  log_retention_days: 30,
  checkpoint_file: "/tmp/arbor/limitless_checkpoint",
  response_recipient: "+15551234567"

# Swoosh: we use SMTP adapter directly, disable the API client
config :swoosh, :api_client, false

# Email channel (outbound only)
config :arbor_comms, :email,
  enabled: true,
  from: System.get_env("SMTP_USER"),
  to: System.get_env("EMAIL_TO"),
  smtp_host: System.get_env("SMTP_HOST"),
  smtp_port: System.get_env("SMTP_PORT"),
  smtp_user: System.get_env("SMTP_USER"),
  smtp_pass: System.get_env("SMTP_PASS"),
  log_dir: "/tmp/arbor/email_chat",
  log_retention_days: 30

# Comms message handler
config :arbor_comms, :handler,
  enabled: true,
  authorized_senders: ["+15551234567"],
  context_file: ".arbor/context/comms_context.md",
  response_generator: Arbor.AI.CommsResponder,
  conversation_window: 20,
  dedup_window_seconds: 300

# Import environment-specific config
import_config "#{config_env()}.exs"
