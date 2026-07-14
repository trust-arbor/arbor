defmodule Arbor.Persistence.RecordsGenerationMigrationTest do
  @moduledoc """
  Hermetic SQLite regression for records generation/deleted_at migration.

  Root cause: Ecto's `add_if_not_exists/3` is not implemented by ecto_sqlite3 and
  raises `ArgumentError: Not supported by SQLite3` on a fresh migration chain.
  MigrationHelper.column_exists?/2 + add_column_if_not_exists/4 is the owning fix.
  """
  use ExUnit.Case, async: false

  @moduletag capture_log: true
  @moduletag :sqlite
  @moduletag :database

  @migration_version 20_260_713_000_002
  @migration_module Arbor.Persistence.Repo.Migrations.RecordsGenerationAndNamespaceKeyIdentity

  @migration_file Path.expand(
                    "../../../priv/repo/migrations/20260713000002_records_generation_and_namespace_key_identity.exs",
                    __DIR__
                  )

  Code.require_file(@migration_file)

  defmodule MigrationRepo do
    use Ecto.Repo,
      otp_app: :arbor_persistence,
      adapter: Ecto.Adapters.SQLite3
  end

  setup do
    previous_adapter = Application.get_env(:arbor_persistence, :repo_adapter)
    Application.put_env(:arbor_persistence, :repo_adapter, Ecto.Adapters.SQLite3)

    database =
      Path.join(
        System.tmp_dir!(),
        "arbor-records-generation-#{System.unique_integer([:positive])}.sqlite3"
      )

    File.rm(database)

    start_supervised!(
      {MigrationRepo, database: database, pool: DBConnection.ConnectionPool, pool_size: 1}
    )

    on_exit(fn ->
      File.rm(database)

      if previous_adapter do
        Application.put_env(:arbor_persistence, :repo_adapter, previous_adapter)
      else
        Application.delete_env(:arbor_persistence, :repo_adapter)
      end
    end)

    {:ok, database: database}
  end

  test "fresh records table gains generation default 1, nullable deleted_at, and unique identity" do
    create_base_records_table!()
    seed_row!("ns", "key-a", "id-a")

    assert :ok == run_migration!()

    assert "generation" in column_names()
    assert "deleted_at" in column_names()
    assert unique_index_exists?("records_namespace_key_index")

    assert %{rows: [[1, nil]]} =
             MigrationRepo.query!(
               "SELECT generation, deleted_at FROM records WHERE id = ?",
               ["id-a"]
             )

    # New inserts inherit generation default 1 and accept NULL deleted_at.
    MigrationRepo.query!("""
    INSERT INTO records (id, namespace, key, data, metadata, revision, inserted_at, updated_at)
    VALUES ('id-b', 'ns', 'key-b', '{}', '{}', 0,
            STRFTIME('%Y-%m-%d %H:%M:%f', 'now'),
            STRFTIME('%Y-%m-%d %H:%M:%f', 'now'))
    """)

    assert %{rows: [[1, nil]]} =
             MigrationRepo.query!(
               "SELECT generation, deleted_at FROM records WHERE id = ?",
               ["id-b"]
             )

    # Physical identity is (namespace, key), not delimiter-collapsed id.
    MigrationRepo.query!("""
    INSERT INTO records (
      id, namespace, key, data, metadata, revision, generation, deleted_at,
      inserted_at, updated_at
    ) VALUES (
      'id-c', 'a', 'b:c', '{}', '{}', 0, 1, NULL,
      STRFTIME('%Y-%m-%d %H:%M:%f', 'now'),
      STRFTIME('%Y-%m-%d %H:%M:%f', 'now')
    )
    """)

    MigrationRepo.query!("""
    INSERT INTO records (
      id, namespace, key, data, metadata, revision, generation, deleted_at,
      inserted_at, updated_at
    ) VALUES (
      'id-d', 'a:b', 'c', '{}', '{}', 0, 1, NULL,
      STRFTIME('%Y-%m-%d %H:%M:%f', 'now'),
      STRFTIME('%Y-%m-%d %H:%M:%f', 'now')
    )
    """)

    assert %{rows: [[2]]} =
             MigrationRepo.query!(
               "SELECT COUNT(*) FROM records WHERE (namespace = 'a' AND key = 'b:c') OR (namespace = 'a:b' AND key = 'c')"
             )
  end

  test "partial upgrade with generation already present still adds deleted_at and index" do
    create_base_records_table!()
    MigrationRepo.query!("ALTER TABLE records ADD COLUMN generation INTEGER NOT NULL DEFAULT 1")
    seed_row!("ns", "partial-gen", "id-partial-gen")

    assert "generation" in column_names()
    refute "deleted_at" in column_names()

    assert :ok == run_migration!()

    assert "generation" in column_names()
    assert "deleted_at" in column_names()
    assert unique_index_exists?("records_namespace_key_index")

    assert %{rows: [[1, nil]]} =
             MigrationRepo.query!(
               "SELECT generation, deleted_at FROM records WHERE id = ?",
               ["id-partial-gen"]
             )
  end

  test "partial upgrade with deleted_at already present still adds generation" do
    create_base_records_table!()
    MigrationRepo.query!("ALTER TABLE records ADD COLUMN deleted_at TEXT")
    seed_row!("ns", "partial-del", "id-partial-del")

    refute "generation" in column_names()
    assert "deleted_at" in column_names()

    assert :ok == run_migration!()

    assert "generation" in column_names()
    assert "deleted_at" in column_names()

    assert %{rows: [[1, nil]]} =
             MigrationRepo.query!(
               "SELECT generation, deleted_at FROM records WHERE id = ?",
               ["id-partial-del"]
             )
  end

  test "fully upgraded schema is a no-op rather than a duplicate-column error" do
    create_base_records_table!()
    MigrationRepo.query!("ALTER TABLE records ADD COLUMN generation INTEGER NOT NULL DEFAULT 1")
    MigrationRepo.query!("ALTER TABLE records ADD COLUMN deleted_at TEXT")

    MigrationRepo.query!("""
    CREATE UNIQUE INDEX records_namespace_key_index ON records (namespace, key)
    """)

    seed_row!("ns", "already", "id-already")

    # Must not raise duplicate-column / duplicate-index errors.
    assert :ok == run_migration!()

    assert "generation" in column_names()
    assert "deleted_at" in column_names()
    assert unique_index_exists?("records_namespace_key_index")
  end

  test "down removes additive columns but keeps namespace/key unique index" do
    create_base_records_table!()
    assert :ok == run_migration!()
    assert "generation" in column_names()
    assert "deleted_at" in column_names()

    assert :ok ==
             Ecto.Migrator.down(MigrationRepo, @migration_version, @migration_module, log: false)

    refute "generation" in column_names()
    refute "deleted_at" in column_names()
    assert unique_index_exists?("records_namespace_key_index")
  end

  defp create_base_records_table! do
    MigrationRepo.query!("""
    CREATE TABLE records (
      id TEXT PRIMARY KEY,
      namespace TEXT NOT NULL,
      key TEXT NOT NULL,
      data TEXT NOT NULL DEFAULT '{}',
      metadata TEXT NOT NULL DEFAULT '{}',
      revision INTEGER NOT NULL DEFAULT 0,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)
  end

  defp seed_row!(namespace, key, id) do
    MigrationRepo.query!(
      """
      INSERT INTO records (id, namespace, key, data, metadata, revision, inserted_at, updated_at)
      VALUES (?, ?, ?, '{}', '{}', 0,
              STRFTIME('%Y-%m-%d %H:%M:%f', 'now'),
              STRFTIME('%Y-%m-%d %H:%M:%f', 'now'))
      """,
      [id, namespace, key]
    )
  end

  defp run_migration! do
    Ecto.Migrator.up(MigrationRepo, @migration_version, @migration_module, log: false)
  end

  defp column_names do
    %{rows: rows} =
      MigrationRepo.query!("SELECT name FROM pragma_table_info('records') ORDER BY cid")

    Enum.map(rows, fn [name] -> name end)
  end

  defp unique_index_exists?(name) do
    %{rows: rows} =
      MigrationRepo.query!(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?",
        [name]
      )

    rows != []
  end
end
