defmodule Arbor.Persistence.VectorStore.EctoSQLiteTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.{VectorOperation, VectorRecord}

  @migration_version 20_260_805_000_001
  @migration_module Arbor.Persistence.Repo.Migrations.PrepareVectorStoreV1
  @widen_migration_version 20_260_805_000_002
  @widen_migration_module Arbor.Persistence.Repo.Migrations.WidenVectorAgentIds
  @isolation_migration_version 20_260_805_000_003
  @isolation_migration_module Arbor.Persistence.Repo.Migrations.IsolateVectorStoreV1Rows
  @migration_file Path.expand(
                    "../../../../priv/repo/migrations/20260805000001_prepare_vector_store_v1.exs",
                    __DIR__
                  )
  @widen_migration_file Path.expand(
                          "../../../../priv/repo/migrations/20260805000002_widen_vector_agent_ids.exs",
                          __DIR__
                        )
  @isolation_migration_file Path.expand(
                              "../../../../priv/repo/migrations/20260805000003_isolate_vector_store_v1_rows.exs",
                              __DIR__
                            )

  Code.require_file(@migration_file)
  Code.require_file(@widen_migration_file)
  Code.require_file(@isolation_migration_file)

  defmodule SQLiteRepo do
    use Ecto.Repo,
      otp_app: :arbor_persistence,
      adapter: Ecto.Adapters.SQLite3
  end

  defmodule RollbackRepo do
    use Ecto.Repo,
      otp_app: :arbor_persistence,
      adapter: Ecto.Adapters.SQLite3
  end

  setup_all do
    database =
      Path.join(
        System.tmp_dir!(),
        "arbor-vector-store-#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!(
      {SQLiteRepo,
       database: database,
       pool: DBConnection.ConnectionPool,
       pool_size: 1,
       busy_timeout: 5_000,
       journal_mode: :wal}
    )

    create_legacy_table!()

    assert :ok ==
             Ecto.Migrator.up(SQLiteRepo, @migration_version, @migration_module, log: false)

    assert :ok ==
             Ecto.Migrator.up(
               SQLiteRepo,
               @widen_migration_version,
               @widen_migration_module,
               log: false
             )

    assert :ok ==
             Ecto.Migrator.up(
               SQLiteRepo,
               @isolation_migration_version,
               @isolation_migration_module,
               log: false
             )

    on_exit(fn ->
      Enum.each([database, database <> "-shm", database <> "-wal"], &File.rm/1)
    end)

    :ok
  end

  setup do
    original_backend =
      Application.get_env(:arbor_persistence, :vector_store_backend, :not_configured)

    original_repo = Application.get_env(:arbor_persistence, :vector_store_repo, :not_configured)

    Application.put_env(
      :arbor_persistence,
      :vector_store_backend,
      Arbor.Persistence.VectorStore.Ecto
    )

    Application.put_env(:arbor_persistence, :vector_store_repo, SQLiteRepo)

    on_exit(fn ->
      restore_env(:vector_store_backend, original_backend)
      restore_env(:vector_store_repo, original_repo)
    end)

    {:ok, agent_id: unique("agent")}
  end

  test "migration is additive and leaves legacy identity intact" do
    columns =
      SQLiteRepo.query!("SELECT name FROM pragma_table_info('memory_embeddings')").rows
      |> List.flatten()

    for legacy <- ["content", "content_hash", "embedding"] do
      assert legacy in columns
    end

    for staged <- [
          "source_namespace",
          "source_key",
          "canonical_payload",
          "payload_digest",
          "vector_768",
          "vector_bytes",
          "vector_protocol",
          "generation",
          "revision",
          "tombstone"
        ] do
      assert staged in columns
    end

    assert %{rows: [[1]]} =
             SQLiteRepo.query!("""
             SELECT COUNT(*)
             FROM sqlite_master
             WHERE type = 'index'
               AND name = 'memory_embeddings_agent_id_content_hash_index'
             """)
  end

  test "security regression: preparation rollback refuses to destroy V1 state" do
    database =
      Path.join(
        System.tmp_dir!(),
        "arbor-vector-rollback-#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!(
      {RollbackRepo,
       database: database, pool: DBConnection.ConnectionPool, pool_size: 1, busy_timeout: 5_000}
    )

    on_exit(fn ->
      Enum.each([database, database <> "-shm", database <> "-wal"], &File.rm/1)
    end)

    create_legacy_table!(RollbackRepo)

    assert :ok ==
             Ecto.Migrator.up(RollbackRepo, @migration_version, @migration_module, log: false)

    now = DateTime.utc_now() |> DateTime.to_iso8601()

    RollbackRepo.query!("""
    INSERT INTO memory_embeddings (
      id, agent_id, content, content_hash, embedding,
      source_namespace, source_key, generation, revision, tombstone,
      inserted_at, updated_at
    ) VALUES (
      'vec_rollback', 'agent_rollback', '{}', '#{String.duplicate("a", 64)}', '[1.0]',
      'voice', 'source', 1, 1, 0, '#{now}', '#{now}'
    )
    """)

    RollbackRepo.query!("""
    INSERT INTO vector_operation_receipts (
      operation_fingerprint, agent_id, operation_kind,
      operation_json, operation_digest, receipt_json, receipt_digest, inserted_at
    ) VALUES (
      '#{String.duplicate("b", 64)}', 'agent_rollback', 'insert',
      '{}', '#{String.duplicate("c", 64)}', '{}', '#{String.duplicate("d", 64)}', '#{now}'
    )
    """)

    assert_raise RuntimeError, ~r/irreversible migration/, fn ->
      Ecto.Migrator.down(RollbackRepo, @migration_version, @migration_module, log: false)
    end

    assert %{rows: [[1]]} =
             RollbackRepo.query!(
               "SELECT COUNT(*) FROM memory_embeddings WHERE id = 'vec_rollback'"
             )

    assert %{rows: [[1]]} =
             RollbackRepo.query!("SELECT COUNT(*) FROM vector_operation_receipts")
  end

  test "equal payloads persist under distinct logical identities", %{agent_id: agent_id} do
    payload = %{"content" => "same canonical payload"}
    first = insert_operation!(record!(agent_id, source_key: "one", payload: payload))
    second = insert_operation!(record!(agent_id, source_key: "two", payload: payload))

    assert {:ok, first_receipt} =
             Arbor.Persistence.execute_vector_operation(agent_id, first)

    assert {:ok, second_receipt} =
             Arbor.Persistence.execute_vector_operation(agent_id, second)

    assert first_receipt.record.id != second_receipt.record.id
    assert first_receipt.record.payload_digest == second_receipt.record.payload_digest

    assert %{rows: [[2, 1]]} =
             SQLiteRepo.query!(
               """
               SELECT COUNT(DISTINCT content_hash), COUNT(DISTINCT payload_digest)
               FROM memory_embeddings
               WHERE agent_id = ?
               """,
               [agent_id]
             )
  end

  test "CRUD fences preserve stable id and reconciliation returns the original receipt", %{
    agent_id: agent_id
  } do
    insert = insert_operation!(record!(agent_id, source_key: "lifecycle"))
    assert {:ok, inserted} = Arbor.Persistence.execute_vector_operation(agent_id, insert)
    assert {1, 1, false} == fence(inserted.record)

    update_record = rebuild_record!(inserted.record, payload: %{"content" => "updated"})
    update = operation!(:update, update_record)
    assert {:ok, updated} = Arbor.Persistence.execute_vector_operation(agent_id, update)

    assert updated.record.id == inserted.record.id
    assert {1, 2, false} == fence(updated.record)

    assert {:ok, ^inserted} =
             Arbor.Persistence.reconcile_vector_operation(agent_id, insert)

    delete = operation!(:delete, updated.record)
    assert {:ok, deleted} = Arbor.Persistence.execute_vector_operation(agent_id, delete)
    assert {1, 3, true} == fence(deleted.record)

    assert {:error, :not_found} =
             Arbor.Persistence.fetch_vector_record(agent_id, "voice", "lifecycle")

    deleted_record = deleted.record

    assert {:ok, ^deleted_record} =
             Arbor.Persistence.fetch_vector_record(agent_id, "voice", "lifecycle",
               include_tombstone: true
             )

    reinsert_record =
      rebuild_record!(deleted.record,
        payload: %{"content" => "reinserted"},
        tombstone: false
      )

    reinsert = operation!(:reinsert, reinsert_record)
    assert {:ok, reinserted} = Arbor.Persistence.execute_vector_operation(agent_id, reinsert)
    assert reinserted.record.id == inserted.record.id
    assert {2, 1, false} == fence(reinserted.record)

    assert {:ok, ^inserted} =
             Arbor.Persistence.reconcile_vector_operation(agent_id, insert)
  end

  test "tenant filters hold and a malformed durable row fails the whole read", %{
    agent_id: agent_id
  } do
    operation = insert_operation!(record!(agent_id, source_key: "malformed"))
    assert {:ok, receipt} = Arbor.Persistence.execute_vector_operation(agent_id, operation)

    other_agent = unique("agent")

    assert {:error, :not_found} =
             Arbor.Persistence.fetch_vector_record(other_agent, "voice", "malformed")

    assert {:ok, []} = Arbor.Persistence.list_vector_records(other_agent)

    SQLiteRepo.query!(
      "UPDATE memory_embeddings SET payload_digest = ? WHERE id = ?",
      [String.duplicate("0", 64), receipt.record.id]
    )

    assert {:error, :backend_failure} =
             Arbor.Persistence.fetch_vector_record(agent_id, "voice", "malformed")

    assert {:error, :backend_failure} = Arbor.Persistence.list_vector_records(agent_id)
    assert {:ok, ^receipt} = Arbor.Persistence.reconcile_vector_operation(agent_id, operation)
  end

  test "a conflicting child rolls back the full bounded batch", %{agent_id: agent_id} do
    shared_id = unique("vec")
    blocker = insert_operation!(record!(agent_id, id: shared_id, source_key: "blocker"))
    assert {:ok, _receipt} = Arbor.Persistence.execute_vector_operation(agent_id, blocker)

    first = insert_operation!(record!(agent_id, source_key: "rolled-back"))
    second = insert_operation!(record!(agent_id, id: shared_id, source_key: "id-conflict"))
    {:ok, batch} = VectorOperation.new(%{kind: :batch, operations: [first, second]})

    assert {:error, :conflict} = Arbor.Persistence.execute_vector_operation(agent_id, batch)

    assert {:error, :not_found} =
             Arbor.Persistence.fetch_vector_record(agent_id, "voice", "rolled-back")

    assert {:ok, :absent} = Arbor.Persistence.reconcile_vector_operation(agent_id, batch)
  end

  test "SQLite search is explicitly unsupported", %{agent_id: agent_id} do
    opts = [
      model_id: "provider/model-v1",
      dimensions: VectorRecord.dimensions(),
      encoding: VectorRecord.encoding(),
      category: "voice"
    ]

    assert {:error, :unsupported} =
             Arbor.Persistence.search_vector_records(agent_id, vector(), opts)
  end

  test "operation receipt ledger rejects mutation", %{agent_id: agent_id} do
    operation = insert_operation!(record!(agent_id, source_key: "immutable-ledger"))
    assert {:ok, _receipt} = Arbor.Persistence.execute_vector_operation(agent_id, operation)

    assert_raise Exqlite.Error, fn ->
      SQLiteRepo.query!(
        "UPDATE vector_operation_receipts SET receipt_digest = ? WHERE operation_fingerprint = ?",
        [String.duplicate("0", 64), operation.fingerprint]
      )
    end

    assert_raise Exqlite.Error, fn ->
      SQLiteRepo.query!(
        "DELETE FROM vector_operation_receipts WHERE operation_fingerprint = ?",
        [operation.fingerprint]
      )
    end
  end

  defp create_legacy_table!(repo \\ SQLiteRepo) do
    repo.query!("""
    CREATE TABLE memory_embeddings (
      id TEXT PRIMARY KEY,
      agent_id TEXT NOT NULL,
      content TEXT NOT NULL,
      content_hash TEXT NOT NULL,
      memory_type TEXT,
      source TEXT,
      metadata TEXT DEFAULT '{}',
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      embedding TEXT
    )
    """)

    repo.query!("""
    CREATE UNIQUE INDEX memory_embeddings_agent_id_content_hash_index
    ON memory_embeddings (agent_id, content_hash)
    """)
  end

  defp record!(agent_id, overrides) do
    overrides = Map.new(overrides)
    payload = Map.get(overrides, :payload, %{"content" => "remember this"})
    vector = Map.get(overrides, :vector, vector())
    {:ok, payload_digest} = VectorRecord.payload_digest(payload)
    {:ok, vector_digest} = VectorRecord.vector_digest(vector)

    attrs = %{
      id: unique("vec"),
      agent_id: agent_id,
      source_namespace: "voice",
      source_key: unique("source"),
      payload: payload,
      vector: vector,
      payload_digest: payload_digest,
      vector_digest: vector_digest,
      model_id: "provider/model-v1",
      dimensions: VectorRecord.dimensions(),
      encoding: VectorRecord.encoding(),
      category: "voice",
      generation: 0,
      revision: 0,
      tombstone: false
    }

    {:ok, record} = VectorRecord.new(Map.merge(attrs, overrides))
    record
  end

  defp rebuild_record!(record, overrides) do
    attrs = Map.merge(Map.from_struct(record), Map.new(overrides))
    {:ok, payload_digest} = VectorRecord.payload_digest(attrs.payload)
    {:ok, vector_digest} = VectorRecord.vector_digest(attrs.vector)

    attrs =
      attrs
      |> Map.put(:payload_digest, payload_digest)
      |> Map.put(:vector_digest, vector_digest)

    {:ok, rebuilt} = VectorRecord.new(attrs)
    rebuilt
  end

  defp insert_operation!(record), do: operation!(:insert, record)

  defp operation!(:insert, record) do
    {:ok, operation} =
      VectorOperation.new(%{
        kind: :insert,
        record: record,
        expected_generation: nil,
        expected_revision: nil
      })

    operation
  end

  defp operation!(kind, record) do
    {:ok, operation} =
      VectorOperation.new(%{
        kind: kind,
        record: record,
        expected_generation: record.generation,
        expected_revision: record.revision
      })

    operation
  end

  defp vector, do: List.duplicate(0.25, VectorRecord.dimensions())
  defp fence(record), do: {record.generation, record.revision, record.tombstone}
  defp unique(prefix), do: "#{prefix}_#{System.unique_integer([:positive, :monotonic])}"

  defp restore_env(key, :not_configured), do: Application.delete_env(:arbor_persistence, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_persistence, key, value)
end
