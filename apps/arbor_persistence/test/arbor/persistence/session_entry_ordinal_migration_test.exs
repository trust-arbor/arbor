defmodule Arbor.Persistence.SessionEntryOrdinalMigrationTest do
  @moduledoc """
  SQLite coverage for the session-entry ordinal migration's deterministic
  backfill and final schema constraints.
  """

  use ExUnit.Case, async: false

  @base_version 20_260_222_100_001
  @migration_version 20_260_804_000_001
  @migration_module Arbor.Persistence.Repo.Migrations.AddSessionEntryOrdinals

  @migrations_path Path.expand("../../../priv/repo/migrations", __DIR__)

  @migration_file Path.expand(
                    "../../../priv/repo/migrations/20260804000001_add_session_entry_ordinals.exs",
                    __DIR__
                  )

  Code.require_file(@migration_file)

  defmodule MigrationRepo do
    use Ecto.Repo,
      otp_app: :arbor_persistence,
      adapter: Ecto.Adapters.SQLite3
  end

  setup do
    database =
      Path.join(
        System.tmp_dir!(),
        "arbor-session-ordinal-migration-#{System.unique_integer([:positive])}.sqlite3"
      )

    File.rm(database)

    start_supervised!(
      {MigrationRepo, database: database, pool: DBConnection.ConnectionPool, pool_size: 1}
    )

    on_exit(fn -> File.rm(database) end)
    :ok
  end

  test "backfills by timestamp and id, then enforces non-null ordinals and uniqueness" do
    migrate_to_base_schema!()
    seed_rows!()

    assert :ok ==
             Ecto.Migrator.up(MigrationRepo, @migration_version, @migration_module, log: false)

    assert %{rows: [[id_c, 1], [id_a, 2], [id_b, 3], [id_d, 1]]} =
             MigrationRepo.query!("""
             SELECT id, entry_ordinal
             FROM session_entries
             ORDER BY session_id, entry_ordinal
             """)

    assert id_c == "00000000-0000-0000-0000-000000000003"
    assert id_a == "00000000-0000-0000-0000-000000000001"
    assert id_b == "00000000-0000-0000-0000-000000000002"
    assert id_d == "00000000-0000-0000-0000-000000000004"

    assert %{rows: [[content, metadata]]} =
             MigrationRepo.query!("""
             SELECT content, metadata
             FROM session_entries
             WHERE id = '00000000-0000-0000-0000-000000000002'
             """)

    assert Jason.decode!(content) == [%{"text" => "00000000-0000-0000-0000-000000000002"}]
    assert Jason.decode!(metadata) == %{"source" => "00000000-0000-0000-0000-000000000002"}

    assert %{rows: [["00000000-0000-0000-0000-000000000001"]]} =
             MigrationRepo.query!(
               "SELECT parent_entry_id FROM session_entries WHERE id = '00000000-0000-0000-0000-000000000002'"
             )

    assert %{rows: [["entry_ordinal", 1]]} =
             MigrationRepo.query!(
               "SELECT name, \"notnull\" FROM pragma_table_info('session_entries') WHERE name = ?",
               ["entry_ordinal"]
             )

    assert %{rows: [[1]]} =
             MigrationRepo.query!("""
             SELECT COUNT(*)
             FROM sqlite_master
             WHERE type = 'index'
               AND name = 'session_entries_session_id_entry_ordinal_index'
             """)

    assert %{rows: [[2]]} =
             MigrationRepo.query!("""
             SELECT COUNT(*)
             FROM sqlite_master
             WHERE type = 'index'
               AND name IN (
                 'session_entries_session_id_timestamp_index',
                 'session_entries_entry_type_index'
               )
             """)

    assert_raise Exqlite.Error, fn ->
      MigrationRepo.query!("""
      INSERT INTO session_entries
        (id, session_id, entry_type, content, timestamp, metadata, entry_ordinal)
      VALUES ('00000000-0000-0000-0000-000000000099', 's1', 'user', '[]',
              '2026-08-04 13:00:00.000000', '{}', 1)
      """)
    end

    assert :ok ==
             Ecto.Migrator.down(MigrationRepo, @migration_version, @migration_module, log: false)

    assert :ok ==
             Ecto.Migrator.up(MigrationRepo, @migration_version, @migration_module, log: false)

    assert %{rows: [[^id_c, 1], [^id_a, 2], [^id_b, 3], [^id_d, 1]]} =
             MigrationRepo.query!("""
             SELECT id, entry_ordinal
             FROM session_entries
             ORDER BY session_id, entry_ordinal
             """)
  end

  test "down removes the ordinal column and unique index" do
    migrate_to_base_schema!()

    assert :ok ==
             Ecto.Migrator.up(MigrationRepo, @migration_version, @migration_module, log: false)

    assert :ok ==
             Ecto.Migrator.down(MigrationRepo, @migration_version, @migration_module, log: false)

    assert %{rows: []} =
             MigrationRepo.query!(
               "SELECT name FROM pragma_table_info('session_entries') WHERE name = ?",
               ["entry_ordinal"]
             )

    assert %{rows: []} =
             MigrationRepo.query!("""
             SELECT name
             FROM sqlite_master
             WHERE type = 'index'
               AND name = 'session_entries_session_id_entry_ordinal_index'
             """)
  end

  defp migrate_to_base_schema! do
    versions =
      Ecto.Migrator.run(MigrationRepo, @migrations_path, :up,
        to: @base_version,
        log: false
      )

    assert @base_version in versions
  end

  defp seed_rows! do
    MigrationRepo.query!("""
    INSERT INTO sessions (id, session_id, agent_id, inserted_at, updated_at)
    VALUES ('s1', 'session-1', 'agent', STRFTIME('%Y-%m-%d %H:%M:%f', 'now'),
            STRFTIME('%Y-%m-%d %H:%M:%f', 'now'))
    """)

    MigrationRepo.query!("""
    INSERT INTO sessions (id, session_id, agent_id, inserted_at, updated_at)
    VALUES ('s2', 'session-2', 'agent', STRFTIME('%Y-%m-%d %H:%M:%f', 'now'),
            STRFTIME('%Y-%m-%d %H:%M:%f', 'now'))
    """)

    for {id, session_id, timestamp} <- [
          {"00000000-0000-0000-0000-000000000002", "s1", "2026-08-04 12:00:00.000000"},
          {"00000000-0000-0000-0000-000000000001", "s1", "2026-08-04 12:00:00.000000"},
          {"00000000-0000-0000-0000-000000000003", "s1", "2026-08-04 11:00:00.000000"},
          {"00000000-0000-0000-0000-000000000004", "s2", "2026-08-04 12:00:00.000000"}
        ] do
      MigrationRepo.query!(
        """
        INSERT INTO session_entries
          (id, session_id, entry_type, content, timestamp, metadata)
        VALUES (?, ?, 'user', ?, ?, ?)
        """,
        [
          id,
          session_id,
          Jason.encode!([%{"text" => id}]),
          timestamp,
          Jason.encode!(%{"source" => id})
        ]
      )
    end

    MigrationRepo.query!("""
    UPDATE session_entries
    SET parent_entry_id = '00000000-0000-0000-0000-000000000001'
    WHERE id = '00000000-0000-0000-0000-000000000002'
    """)
  end
end
