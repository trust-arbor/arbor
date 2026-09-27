defmodule Arbor.Comms.TestConversationSQLite do
  @moduledoc false

  defmodule Repo do
    use Ecto.Repo, otp_app: :arbor_comms, adapter: Ecto.Adapters.SQLite3
  end

  @migration_root Path.expand("../../../arbor_persistence/priv/repo/migrations", __DIR__)

  def create_schema!(repo) do
    repo.query!("""
    CREATE TABLE events (
      id TEXT PRIMARY KEY, stream_id TEXT NOT NULL, event_number INTEGER NOT NULL,
      global_position INTEGER, type TEXT NOT NULL, data TEXT DEFAULT '{}',
      metadata TEXT DEFAULT '{}', agent_id TEXT, causation_id TEXT, correlation_id TEXT,
      event_timestamp TEXT, committed_at TEXT, created_at TEXT NOT NULL
    )
    """)

    repo.query!(
      "CREATE UNIQUE INDEX events_stream_id_event_number_index ON events (stream_id, event_number)"
    )

    repo.query!("CREATE UNIQUE INDEX events_global_position_index ON events (global_position)")

    repo.query!("""
    CREATE TABLE event_log_operations (
      operation_id TEXT PRIMARY KEY, stream_id TEXT NOT NULL, identity TEXT NOT NULL,
      status TEXT NOT NULL, reason TEXT, inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL
    )
    """)

    repo.query!("""
    CREATE TRIGGER events_set_committed_at_after_insert AFTER INSERT ON events FOR EACH ROW
    BEGIN
      UPDATE events SET committed_at = STRFTIME('%Y-%m-%d %H:%M:%f', 'now') WHERE id = NEW.id;
    END
    """)

    for {version, file, module} <- [
          {20_260_712_000_004, "20260712000004_enforce_event_log_protocol.exs",
           Arbor.Persistence.Repo.Migrations.EnforceEventLogProtocol},
          {20_260_712_000_005, "20260712000005_harden_event_log_protocol_epoch.exs",
           Arbor.Persistence.Repo.Migrations.HardenEventLogProtocolEpoch}
        ] do
      unless Code.ensure_loaded?(module), do: Code.require_file(Path.join(@migration_root, file))
      :ok = Ecto.Migrator.up(repo, version, module, log: false)
    end

    :ok
  end

  def configure(repo \\ Repo) do
    Application.put_env(:arbor_comms, :conversation_journal,
      backend: Arbor.Persistence.EventLog.Ecto,
      name: :conversation_journal_test,
      opts: [repo: repo, timeout_ms: 5_000]
    )
  end
end
