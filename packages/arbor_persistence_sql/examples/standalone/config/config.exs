import Config

config :logger, level: :warning

{:ok, [database_options]} =
  System.fetch_env!("PERSISTENCE_DATABASE_CONFIG")
  |> String.to_charlist()
  |> :file.consult()

adapter =
  case System.fetch_env!("PERSISTENCE_DATABASE_KIND") do
    "sqlite" -> Ecto.Adapters.SQLite3
    "postgres" -> Ecto.Adapters.Postgres
  end

config :arbor_persistence_sql,
  repo: Arbor.Persistence.SQL.Repo,
  repo_adapter: adapter,
  ecto_repos: [Arbor.Persistence.SQL.Repo]

config :arbor_persistence_sql,
       Arbor.Persistence.SQL.Repo,
       Keyword.merge(database_options, pool_size: 2, stacktrace: false, log: false)
