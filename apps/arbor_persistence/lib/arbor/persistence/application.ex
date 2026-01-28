defmodule Arbor.Persistence.Application do
  @moduledoc """
  Optional application for Arbor.Persistence.

  ## Postgres Support

  To enable the Postgres backend, configure the Repo and set `start_repo: true`:

      config :arbor_persistence,
        start_repo: true

      config :arbor_persistence, Arbor.Persistence.Repo,
        database: "arbor_dev",
        username: "postgres",
        password: "postgres",
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
    if Application.get_env(:arbor_persistence, :start_repo, false) do
      [Arbor.Persistence.Repo]
    else
      []
    end
  end
end
