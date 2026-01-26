import Config

# Common configuration for all Arbor apps
config :logger,
  level: :info

# Import environment-specific config
import_config "#{config_env()}.exs"
