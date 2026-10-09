if Mix.env() == :test do
  defmodule Arbor.Historian.TestAuditRepo do
    @moduledoc false
    use Ecto.Repo, otp_app: :arbor_historian, adapter: Ecto.Adapters.SQLite3
  end

  defmodule Arbor.Historian.TestAuditRuntime do
    @moduledoc """
    A private durable audit sink for consumer-app test helpers.

    Non-database suites can make thousands of authority mutations. The real
    journal must retain pending records until a durable Historian consumer
    acknowledges them; this fixture supplies that consumer and an isolated SQL
    target without touching the developer database.
    """

    alias Arbor.Historian.{AuthorityAuditPuller, TestAuditRepo}

    def start_default_lane! do
      if private_database_lane?(System.argv()), do: :ok, else: start!()
    end

    def start! do
      case Process.whereis(TestAuditRepo) do
        nil -> start_runtime!()
        pid when is_pid(pid) -> :ok
      end
    end

    defp private_database_lane?(args) do
      Enum.chunk_every(args, 2, 1, :discard)
      |> Enum.any?(fn
        [flag, tag] when flag in ["--only", "--include"] ->
          tag in ["database", "database:true", "isolated_repo", "isolated_repo:true"]

        _ ->
          false
      end) or
        Enum.any?(
          args,
          &(&1 in ["--only=database", "--include=database", "--include=isolated_repo"])
        )
    end

    defp start_runtime! do
      root =
        Path.join(
          System.tmp_dir!(),
          "arbor-test-authority-audit-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)

      supervisor = Process.whereis(Arbor.Historian.Supervisor)
      true = is_pid(supervisor)

      {:ok, _repo} =
        Supervisor.start_child(
          supervisor,
          {TestAuditRepo,
           database: Path.join(root, "audit.sqlite3"),
           pool: DBConnection.ConnectionPool,
           pool_size: 4,
           busy_timeout: 5_000,
           journal_mode: :wal}
        )

      migrations = Application.app_dir(:arbor_persistence, "priv/repo/migrations")
      _ = Ecto.Migrator.run(TestAuditRepo, migrations, :up, all: true, log: false)

      Application.put_env(:arbor_historian, :durable_event_log_target, %{
        name: :test_authority_audit,
        backend: Arbor.Persistence.EventLog.Ecto,
        opts: [repo: TestAuditRepo]
      })

      Application.put_env(:arbor_security, :authority_audit_consumer_name, AuthorityAuditPuller)

      Application.put_env(
        :arbor_security,
        :authority_audit_consumer_application,
        :arbor_historian
      )

      {:ok, _puller} =
        Supervisor.start_child(supervisor, {AuthorityAuditPuller, poll_interval_ms: 25})

      System.at_exit(fn _status -> File.rm_rf(root) end)
      :ok
    end
  end
end
