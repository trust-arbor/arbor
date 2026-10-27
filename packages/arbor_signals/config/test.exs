import Config

config :logger, level: :warning

config :arbor_signals,
  expose_test_fixtures: true,
  start_children: false,
  checkpoint_module: nil,
  checkpoint_store: nil,
  authorizer: Arbor.Signals.Adapters.OpenAuthorizer,
  allow_open_authorizer: true
