import Config

adapter =
  case System.get_env("PERSISTENCE_SQL_ADAPTER", "sqlite") do
    "sqlite" -> Ecto.Adapters.SQLite3
    "postgres" -> Ecto.Adapters.Postgres
    value -> raise "unsupported PERSISTENCE_SQL_ADAPTER: #{inspect(value)}"
  end

config :arbor_persistence_sql, repo_adapter: adapter

if adapter == Ecto.Adapters.SQLite3 do
  config :arbor_persistence_sql, Arbor.Persistence.SQL.Repo,
    database: System.get_env("PERSISTENCE_SQLITE_PATH", ":memory:"),
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 4,
    busy_timeout: 5_000,
    journal_mode: :wal,
    stacktrace: true
else
  config :arbor_persistence_sql, Arbor.Persistence.SQL.Repo,
    database: System.get_env("PERSISTENCE_POSTGRES_DB"),
    username: System.get_env("PERSISTENCE_POSTGRES_USER", "postgres"),
    password: System.get_env("PERSISTENCE_POSTGRES_PASSWORD", ""),
    hostname: System.get_env("PERSISTENCE_POSTGRES_HOST", "127.0.0.1"),
    port: String.to_integer(System.get_env("PERSISTENCE_POSTGRES_PORT", "5432")),
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 4,
    prepare: :unnamed,
    stacktrace: true
end
