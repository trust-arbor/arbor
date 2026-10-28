ExUnit.start(exclude: [:database, :isolated_repo, :llm, :llm_local])

selected_database_lane? =
  ExUnit.configuration()
  |> Keyword.get(:include, [])
  |> Enum.any?(fn
    tag when tag in [:database, :integration, :isolated_repo] -> true
    {tag, true} when tag in [:database, :integration, :isolated_repo] -> true
    _ -> false
  end)

migrate? = System.get_env("PERSISTENCE_MIGRATE") == "1"

if selected_database_lane? or migrate? do
  case System.get_env("PERSISTENCE_SQL_ADAPTER", "sqlite") do
    "sqlite" ->
      database = System.fetch_env!("PERSISTENCE_SQLITE_PATH")

      unless Path.type(database) == :absolute,
        do: raise("use an explicit absolute private SQLite path")

    "postgres" ->
      Enum.each(
        ~w(PERSISTENCE_POSTGRES_DB PERSISTENCE_POSTGRES_HOST PERSISTENCE_POSTGRES_PORT PERSISTENCE_POSTGRES_USER),
        &System.fetch_env!/1
      )

    _ ->
      raise "unsupported PERSISTENCE_SQL_ADAPTER"
  end
end

if migrate? do
  {:ok, repo} = Arbor.Persistence.SQL.Repo.start_link()

  try do
    Ecto.Migrator.run(Arbor.Persistence.SQL.Repo, :up, all: true, log: false)
  after
    Supervisor.stop(repo)
  end
end
