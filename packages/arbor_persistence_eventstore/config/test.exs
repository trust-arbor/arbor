import Config

if database = System.get_env("PERSISTENCE_POSTGRES_DB") do
  config :arbor_persistence_eventstore, Arbor.Persistence.Ecto.EventStore,
    database: database,
    username: System.get_env("PERSISTENCE_POSTGRES_USER", "postgres"),
    password: System.get_env("PERSISTENCE_POSTGRES_PASSWORD", ""),
    hostname: System.get_env("PERSISTENCE_POSTGRES_HOST", "127.0.0.1"),
    port: String.to_integer(System.get_env("PERSISTENCE_POSTGRES_PORT", "5432")),
    schema: "public",
    serializer: Arbor.Persistence.Ecto.EventSerializer,
    pool_size: 4,
    prepare: :unnamed
end
