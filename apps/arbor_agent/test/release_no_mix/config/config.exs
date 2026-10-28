import Config
config :logger, level: :error
config :arbor_agent, start_children: false
config :arbor_orchestrator, start_children: false

config :arbor_persistence,
  contract_modules: %{
    record: Arbor.Contracts.Persistence.Record,
    revision: Arbor.Contracts.Persistence.Revision,
    filter: Arbor.Contracts.Persistence.Filter,
    append_operation: Arbor.Contracts.Persistence.AppendOperation
  },
  authorization_provider: Arbor.Security,
  event_bus: Arbor.Signals

config :arbor_persistence_sql, repo: Arbor.Persistence.Repo
