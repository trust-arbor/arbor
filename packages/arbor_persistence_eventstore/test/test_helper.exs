ExUnit.start(exclude: [:database, :llm, :llm_local])

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
  Enum.each(
    ~w(PERSISTENCE_POSTGRES_DB PERSISTENCE_POSTGRES_HOST PERSISTENCE_POSTGRES_PORT PERSISTENCE_POSTGRES_USER),
    &System.fetch_env!/1
  )
end

if migrate? do
  Mix.Task.run("event_store.init", ["-e", "Arbor.Persistence.Ecto.EventStore"])
end
