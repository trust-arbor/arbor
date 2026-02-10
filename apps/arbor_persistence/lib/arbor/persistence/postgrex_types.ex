Postgrex.Types.define(
  Arbor.Persistence.PostgrexTypes,
  Pgvector.extensions() ++ Ecto.Adapters.Postgres.extensions(),
  []
)
