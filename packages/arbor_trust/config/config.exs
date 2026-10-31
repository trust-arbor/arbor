import Config
config :arbor_trust, runtime: [start_profile: :full]
if config_env() == :test, do: import_config("test.exs")
