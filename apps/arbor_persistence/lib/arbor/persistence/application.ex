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
    children =
      if Application.get_env(:arbor_persistence, :start_children, true) do
        build_children()
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Arbor.Persistence.Supervisor)
  end

  defp build_children do
    checkpoint = [{Arbor.Persistence.Checkpoint.Store.ETS, []}]
    stores = default_stores()
    repo = if Application.get_env(:arbor_persistence, :start_repo, false), do: [Arbor.Persistence.Repo], else: []
    scheduler = if backup_scheduler_enabled?(), do: [Arbor.Persistence.Backup.Scheduler], else: []
    snapshotter = if snapshotter_enabled?(), do: [snapshotter_spec()], else: []
    checkpoint ++ stores ++ repo ++ scheduler ++ snapshotter
  end

  defp backup_scheduler_enabled? do
    # Only start scheduler when repo is started and backup is enabled
    start_repo = Application.get_env(:arbor_persistence, :start_repo, false)
    backup_config = Application.get_env(:arbor_persistence, :backup, [])
    backup_enabled = Keyword.get(backup_config, :enabled, false)
    start_repo and backup_enabled
  end

  defp snapshotter_enabled? do
    config = Application.get_env(:arbor_persistence, :event_log_snapshot, [])
    Keyword.get(config, :enabled, false)
  end

  defp snapshotter_spec do
    config = Application.get_env(:arbor_persistence, :event_log_snapshot, [])

    {Arbor.Persistence.EventLog.Snapshotter,
     [
       event_log_name: Keyword.get(config, :event_log_name, :event_log),
       store: Keyword.get(config, :store),
       store_opts: Keyword.get(config, :store_opts, []),
       interval_ms: Keyword.get(config, :interval_ms, 300_000),
       event_threshold: Keyword.get(config, :event_threshold, 1_000),
       retention: Keyword.get(config, :retention, 5)
     ]}
  end

  defp default_stores do
    Application.get_env(:arbor_persistence, :stores, [
      {Arbor.Persistence.QueryableStore.ETS, name: :jobs},
      {Arbor.Persistence.EventLog.ETS, name: :event_log}
    ])
  end
end
