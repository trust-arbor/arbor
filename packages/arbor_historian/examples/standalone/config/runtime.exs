import Config
# Every provider binding is explicit. No parent or product configuration is read.
config :arbor_historian,
  start_children: true,
  authorizer: nil,
  authority_source: nil,
  event_provider: nil,
  durable_event_log_target: nil,
  hot_event_log_target: %{
    name: Arbor.Historian.EventLog.ETS,
    backend: Arbor.Persistence.EventLog.ETS,
    opts: []
  }
