import Config

# Common configuration for all Arbor apps
config :logger,
  level: :info

# Allow all custom metadata keys in Logger output.
# Arbor libraries use structured logging with keys like :agent_id, :tool, etc.
config :logger, :default_formatter, metadata: :all

# Import environment-specific config
import_config "#{config_env()}.exs"
