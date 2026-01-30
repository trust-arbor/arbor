defmodule Arbor.Persistence.Application do
  @moduledoc """
  Optional application for Arbor.Persistence.

  ## Postgres Support

  To enable the Postgres backend, configure the Repo and set `start_repo: true`:

      config :arbor_persistence,
        start_repo: true

      config :arbor_persistence, Arbor.Persistence.Repo,
        database: "arbor_dev",
        username: System.get_env("DB_USER", "postgres"),
        password: System.get_env("DB_PASS", "postgres"),
        hostname: "localhost",
        pool_size: 10

  Then run migrations:

      mix ecto.create -r Arbor.Persistence.Repo
      mix ecto.migrate -r Arbor.Persistence.Repo
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = build_children()
    Supervisor.start_link(children, strategy: :one_for_one, name: Arbor.Persistence.Supervisor)
  end

  defp build_children do
    stores = default_stores()
    repo = if Application.get_env(:arbor_persistence, :start_repo, false), do: [Arbor.Persistence.Repo], else: []
    stores ++ repo
  end

  defp default_stores do
    Application.get_env(:arbor_persistence, :stores, [
      {Arbor.Persistence.QueryableStore.ETS, name: :jobs},
      {Arbor.Persistence.EventLog.ETS, name: :event_log}
    ])
  end
end
