import Config

config :logger, level: :warning

# Don't start HTTP server in tests
config :arbor_bridge, start_server: false
