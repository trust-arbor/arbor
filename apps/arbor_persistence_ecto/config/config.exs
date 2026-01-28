import Config

# Default EventStore configuration
# Override in dev.exs, test.exs, or runtime.exs as needed

config :arbor_persistence_ecto, Arbor.Persistence.Ecto.EventStore,
  serializer: EventStore.JsonSerializer,
  schema_prefix: "trust_arbor",
  column_data_type: "jsonb",
  pool_size: 10

# Import environment specific config
import_config "#{config_env()}.exs"
