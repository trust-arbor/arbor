import Config

config :logger, level: :warning

{:ok, [database_options]} =
  System.fetch_env!("PERSISTENCE_DATABASE_CONFIG")
  |> String.to_charlist()
  |> :file.consult()

config :arbor_persistence_eventstore,
       Arbor.Persistence.Ecto.EventStore,
       Keyword.merge(database_options,
         schema: "public",
         serializer: Arbor.Persistence.Ecto.EventSerializer,
         prepare: :unnamed,
         pool_size: 2
       )
