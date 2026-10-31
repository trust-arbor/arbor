import Config

config :arbor_historian,
  start_children: false,
  authorizer: nil,
  authority_source: nil,
  event_provider: nil,
  durable_event_log_target: nil
