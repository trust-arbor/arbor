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
  log_path: "/tmp/arbor/signal_chat.log"

# Import environment-specific config
import_config "#{config_env()}.exs"
