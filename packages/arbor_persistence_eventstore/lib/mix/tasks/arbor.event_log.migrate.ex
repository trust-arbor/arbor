defmodule Mix.Tasks.Arbor.EventLog.Migrate do
  @shortdoc "Migrates Arbor's EventStore EventLog schema"

  use Mix.Task

  alias Arbor.Persistence.Ecto.EventLogSchema
  alias Arbor.Persistence.Ecto.EventStore, as: Store

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("compile")
    {:ok, _applications} = Application.ensure_all_started(:postgrex)
    {:ok, _applications} = Application.ensure_all_started(:ssl)

    config = Store.config()
    schema = Keyword.fetch!(config, :schema)

    connection_opts =
      config
      |> EventStore.Config.default_postgrex_opts()
      |> Keyword.put(:types, EventStore.PostgresTypes)

    unless valid_database?(connection_opts) do
      Mix.raise(
        "Arbor.Persistence.Ecto.EventStore has no database configured; " <>
          "configure it before running arbor.event_log.migrate"
      )
    end

    {:ok, conn} = Postgrex.start_link(connection_opts)

    try do
      :ok = EventLogSchema.migrate!(conn, schema)
      Mix.shell().info("Arbor EventLog schema is current in #{schema}")
    after
      GenServer.stop(conn)
    end
  end

  defp valid_database?(opts) do
    case Keyword.fetch(opts, :database) do
      {:ok, database} when is_binary(database) -> String.trim(database) != ""
      _missing_or_invalid -> false
    end
  end
end
