defmodule Arbor.Persistence.VectorStore.EctoSQLiteTest do
  use ExUnit.Case, async: false

  @moduletag :database
  @moduletag :integration
  @moduletag :sqlite

  alias Arbor.Contracts.Persistence.{VectorOperation, VectorReceipt, VectorRecord}
  alias Arbor.Persistence.VectorStore.Ecto.Codec

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
  @receipt_guard_migration_version 20_260_805_000_004
  @receipt_guard_migration_file Path.expand(
                                  "../../../../priv/repo/migrations/20260805000004_harden_vector_receipt_inserts.exs",
                                  __DIR__
                                )
  @receipt_rowid_guard_migration_version 20_260_805_000_005
  @receipt_rowid_guard_migration_file Path.expand(
                                        "../../../../priv/repo/migrations/20260805000005_harden_vector_receipt_rowids.exs",
                                        __DIR__
                                      )
  @fence_migration_version 20_260_807_000_001
  @fence_migration_file Path.expand(
                          "../../../../priv/repo/migrations/20260807000001_create_vector_agent_fences.exs",
                          __DIR__
                        )

  Code.require_file(@migration_file)
  Code.require_file(@widen_migration_file)
  Code.require_file(@isolation_migration_file)
  Code.require_file(@fence_migration_file)

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

  defmodule BackfillRepo do
    use Ecto.Repo,
      otp_app: :arbor_persistence,
      adapter: Ecto.Adapters.SQLite3
  end

  defmodule RestartRepo do
    use Ecto.Repo,
      otp_app: :arbor_persistence,
      adapter: Ecto.Adapters.SQLite3
  end

  defmodule CollisionRepo do
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
       journal_mode: :wal,
       custom_pragmas: [recursive_triggers: true]}
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

    maybe_install_receipt_insert_guard!()
    maybe_install_fence_migration!()

    on_exit(fn ->
      Enum.each([database, database <> "-shm", database <> "-wal"], &File.rm/1)
    end)

    {:ok, database_path: database}
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

  use Arbor.Persistence.VectorStore.LegacyIsolationConformance,
    repo: SQLiteRepo

  use Arbor.Persistence.LegacyEmbeddingDestroyConformance,
    repo: SQLiteRepo

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
       database: database,
       pool: DBConnection.ConnectionPool,
       pool_size: 1,
       busy_timeout: 5_000,
       custom_pragmas: [recursive_triggers: true]}
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

  test "widening migration refuses to fake a destructive rollback" do
    assert_raise RuntimeError, ~r/irreversible migration/, fn ->
      @widen_migration_module.down()
    end
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

  test "response loss and duplicate execution recover the exact original receipt", %{
    agent_id: agent_id
  } do
    operation = insert_operation!(record!(agent_id, source_key: "response-loss"))
    expected_record = rebuild_record!(operation.record, generation: 1, revision: 1)
    {:ok, expected_receipt} = VectorReceipt.new(%{operation: operation, record: expected_record})

    assert :response_lost = execute_and_discard_response(agent_id, operation)

    assert {:ok, ^expected_receipt} =
             Arbor.Persistence.execute_vector_operation(agent_id, operation)

    update_record = rebuild_record!(expected_record, payload: %{"content" => "later update"})
    update = operation!(:update, update_record)
    assert {:ok, _updated} = Arbor.Persistence.execute_vector_operation(agent_id, update)

    assert {:ok, ^expected_receipt} =
             Arbor.Persistence.reconcile_vector_operation(agent_id, operation)
  end

  test "SQLite stale-fence CAS rejects a second claimant without a concurrency claim", %{
    agent_id: agent_id
  } do
    insert = insert_operation!(record!(agent_id, source_key: "stale-fence"))
    assert {:ok, inserted} = Arbor.Persistence.execute_vector_operation(agent_id, insert)

    winner_record = rebuild_record!(inserted.record, payload: %{"claimant" => "winner"})
    stale_record = rebuild_record!(inserted.record, payload: %{"claimant" => "stale"})

    assert {:ok, winner} =
             Arbor.Persistence.execute_vector_operation(
               agent_id,
               operation!(:update, winner_record)
             )

    assert {:error, :conflict} =
             Arbor.Persistence.execute_vector_operation(
               agent_id,
               operation!(:update, stale_record)
             )

    winner_record = winner.record

    assert {:ok, ^winner_record} =
             Arbor.Persistence.fetch_vector_record(agent_id, "voice", "stale-fence")
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

  test "security regression: public reads reject oversized and deeply nested payload JSON", %{
    agent_id: agent_id
  } do
    limits = VectorRecord.limits().payload
    oversized_record = record!(agent_id, source_key: "oversized-payload")
    deep_record = record!(agent_id, source_key: "deep-payload")

    for record <- [oversized_record, deep_record] do
      assert {:ok, _receipt} =
               Arbor.Persistence.execute_vector_operation(agent_id, insert_operation!(record))
    end

    oversized = "\"" <> String.duplicate("x", limits.max_payload_bytes) <> "\""

    deeply_nested =
      String.duplicate("[", limits.max_depth + 2) <>
        "0" <> String.duplicate("]", limits.max_depth + 2)

    SQLiteRepo.query!(
      "UPDATE memory_embeddings SET canonical_payload = ?, content = ? WHERE id = ?",
      [oversized, oversized, oversized_record.id]
    )

    SQLiteRepo.query!(
      "UPDATE memory_embeddings SET canonical_payload = ?, content = ? WHERE id = ?",
      [deeply_nested, deeply_nested, deep_record.id]
    )

    assert {:error, :backend_failure} =
             Arbor.Persistence.fetch_vector_record(
               agent_id,
               oversized_record.source_namespace,
               oversized_record.source_key
             )

    assert {:error, :backend_failure} =
             Arbor.Persistence.fetch_vector_record(
               agent_id,
               deep_record.source_namespace,
               deep_record.source_key
             )

    assert {:error, :backend_failure} = Arbor.Persistence.list_vector_records(agent_id)
  end

  test "security regression: SQLite mirrors reject oversized and deeply nested JSON", %{
    agent_id: agent_id
  } do
    oversized_record = record!(agent_id, source_key: "oversized-mirror")
    deep_record = record!(agent_id, source_key: "deep-mirror")

    for record <- [oversized_record, deep_record] do
      assert {:ok, _receipt} =
               Arbor.Persistence.execute_vector_operation(agent_id, insert_operation!(record))
    end

    oversized =
      "\"" <> String.duplicate("x", VectorRecord.limits().payload.max_payload_bytes) <> "\""

    deeply_nested = String.duplicate("[", 64) <> "1" <> String.duplicate("]", 64)

    SQLiteRepo.query!(
      "UPDATE memory_embeddings SET vector_768 = ?, embedding = ? WHERE id = ?",
      [oversized, oversized, oversized_record.id]
    )

    SQLiteRepo.query!(
      "UPDATE memory_embeddings SET vector_768 = ?, embedding = ? WHERE id = ?",
      [deeply_nested, deeply_nested, deep_record.id]
    )

    assert {:error, :backend_failure} =
             Arbor.Persistence.fetch_vector_record(
               agent_id,
               oversized_record.source_namespace,
               oversized_record.source_key
             )

    assert {:error, :backend_failure} =
             Arbor.Persistence.fetch_vector_record(
               agent_id,
               deep_record.source_namespace,
               deep_record.source_key
             )
  end

  test "security regression: immutable ledger JSON is bounded before reconciliation", %{
    agent_id: agent_id
  } do
    limits = Codec.limits()
    oversized = "\"" <> String.duplicate("x", limits.max_ledger_json_bytes) <> "\""

    deeply_nested =
      String.duplicate("[", limits.max_ledger_json_containers + 1) <>
        "0" <> String.duplicate("]", limits.max_ledger_json_containers + 1)

    assert {:error, :invalid_codec} = Codec.preflight_ledger_json(oversized)
    assert {:error, :invalid_codec} = Codec.preflight_ledger_json(deeply_nested)
    assert :ok = Codec.preflight_ledger_json(~s({"literal":"[{}]"}))

    corruptions = [
      {:operation_json, oversized},
      {:operation_json, deeply_nested},
      {:receipt_json, oversized},
      {:receipt_json, deeply_nested}
    ]

    for {{field, corrupt_json}, index} <- Enum.with_index(corruptions, 1) do
      operation =
        insert_operation!(record!(agent_id, source_key: "ledger-corrupt-#{index}"))

      {:ok, valid_operation_json} = Codec.encode_operation(operation)

      {operation_json, receipt_json} =
        case field do
          :operation_json -> {corrupt_json, "{}"}
          :receipt_json -> {valid_operation_json, corrupt_json}
        end

      insert_forged_ledger!(operation, operation_json, receipt_json)

      assert {:error, :indeterminate} =
               Arbor.Persistence.reconcile_vector_operation(agent_id, operation)
    end
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
    before_count =
      SQLiteRepo.query!("SELECT COUNT(*) FROM memory_embeddings").rows |> hd() |> hd()

    expanded_opts = [
      model_id: "provider/model-v1",
      dimensions: VectorRecord.dimensions(),
      encoding: VectorRecord.encoding(),
      source_namespace: "voice",
      threshold: 0.5,
      limit: 1000
    ]

    assert {:error, :unsupported} =
             Arbor.Persistence.search_vector_records(agent_id, vector(), expanded_opts)

    assert {:error, :unsupported} =
             Arbor.Persistence.search_vector_records(
               agent_id,
               vector(),
               Keyword.put(expanded_opts, :category, "voice")
             )

    after_count =
      SQLiteRepo.query!("SELECT COUNT(*) FROM memory_embeddings").rows |> hd() |> hd()

    assert after_count == before_count
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

  test "destroy removes exact-agent strict rows and receipts, preserves legacy and survivors", %{
    agent_id: agent_id
  } do
    survivor_id = unique("agent")
    target = insert_operation!(record!(agent_id, source_key: "destroy-target"))
    survivor = insert_operation!(record!(survivor_id, source_key: "destroy-survivor"))

    assert {:ok, _} = Arbor.Persistence.execute_vector_operation(agent_id, target)
    assert {:ok, _} = Arbor.Persistence.execute_vector_operation(survivor_id, survivor)

    now = DateTime.utc_now() |> DateTime.to_iso8601()
    legacy_id = unique("legacy")

    SQLiteRepo.query!(
      """
      INSERT INTO memory_embeddings (
        id, agent_id, content, content_hash, embedding,
        vector_protocol, source_namespace, source_key,
        generation, revision, tombstone, inserted_at, updated_at
      ) VALUES (
        ?, ?, '{}', ?, '[0.1]',
        NULL, NULL, NULL,
        NULL, NULL, NULL, ?, ?
      )
      """,
      [legacy_id, agent_id, String.duplicate("a", 64), now, now]
    )

    assert :ok = Arbor.Persistence.destroy_vector_agent(agent_id)

    assert %{rows: [[0]]} =
             SQLiteRepo.query!(
               """
               SELECT COUNT(*) FROM memory_embeddings
               WHERE agent_id = ? AND vector_protocol = 'arbor_vector_store_v1'
               """,
               [agent_id]
             )

    assert %{rows: [[0]]} =
             SQLiteRepo.query!(
               "SELECT COUNT(*) FROM vector_operation_receipts WHERE agent_id = ?",
               [agent_id]
             )

    assert %{rows: [[1]]} =
             SQLiteRepo.query!(
               "SELECT COUNT(*) FROM memory_embeddings WHERE id = ?",
               [legacy_id]
             )

    assert %{rows: [[1]]} =
             SQLiteRepo.query!(
               """
               SELECT COUNT(*) FROM memory_embeddings
               WHERE agent_id = ? AND vector_protocol = 'arbor_vector_store_v1'
               """,
               [survivor_id]
             )

    assert %{rows: [[1]]} =
             SQLiteRepo.query!(
               "SELECT COUNT(*) FROM vector_operation_receipts WHERE agent_id = ?",
               [survivor_id]
             )

    assert %{rows: [["closed", closed_at]]} =
             SQLiteRepo.query!(
               "SELECT state, closed_at FROM vector_agent_fences WHERE agent_id = ?",
               [agent_id]
             )

    assert is_binary(closed_at) and closed_at != ""

    assert {:error, :closed} =
             Arbor.Persistence.execute_vector_operation(
               agent_id,
               insert_operation!(record!(agent_id, source_key: "after-destroy"))
             )

    assert {:error, :closed} =
             Arbor.Persistence.reconcile_vector_operation(agent_id, target)

    assert {:error, :closed} =
             Arbor.Persistence.fetch_vector_record(agent_id, "voice", "destroy-target")

    assert {:error, :closed} = Arbor.Persistence.list_vector_records(agent_id)

    assert {:error, :closed} =
             Arbor.Persistence.search_vector_records(agent_id, vector(), search_opts())
  end

  test "security regression: public execute fails closed after destroy", %{agent_id: agent_id} do
    operation = insert_operation!(record!(agent_id, source_key: "security-closed"))
    assert {:ok, _} = Arbor.Persistence.execute_vector_operation(agent_id, operation)
    assert :ok = Arbor.Persistence.destroy_vector_agent(agent_id)

    assert {:error, :closed} =
             Arbor.Persistence.execute_vector_operation(
               agent_id,
               insert_operation!(record!(agent_id, source_key: "security-closed-retry"))
             )
  end

  test "security regression: public execute rejects a manually seeded closed fence", %{
    agent_id: agent_id
  } do
    # Keep this fixture self-contained so the test-only parent can prove the old
    # public execute path ignored durable fence state before the migration exists.
    SQLiteRepo.query!("""
    CREATE TABLE IF NOT EXISTS vector_agent_fences (
      agent_id TEXT PRIMARY KEY NOT NULL,
      state TEXT NOT NULL,
      closed_at TEXT,
      updated_at TEXT NOT NULL
    )
    """)

    SQLiteRepo.query!(
      """
      INSERT INTO vector_agent_fences (agent_id, state, closed_at, updated_at)
      VALUES (?, 'closed', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      """,
      [agent_id]
    )

    assert {:error, :closed} =
             Arbor.Persistence.execute_vector_operation(
               agent_id,
               insert_operation!(record!(agent_id, source_key: "manual-closed-attempt"))
             )

    assert %{rows: [[0]]} =
             SQLiteRepo.query!(
               """
               SELECT COUNT(*) FROM memory_embeddings
               WHERE agent_id = ? AND vector_protocol = 'arbor_vector_store_v1'
               """,
               [agent_id]
             )

    assert %{rows: [[0]]} =
             SQLiteRepo.query!(
               "SELECT COUNT(*) FROM vector_operation_receipts WHERE agent_id = ?",
               [agent_id]
             )
  end

  test "idempotent destroy from closed cleans injected debris and recloses", %{
    agent_id: agent_id
  } do
    operation = insert_operation!(record!(agent_id, source_key: "closed-retry"))
    assert {:ok, _} = Arbor.Persistence.execute_vector_operation(agent_id, operation)
    assert :ok = Arbor.Persistence.destroy_vector_agent(agent_id)
    assert :ok = Arbor.Persistence.destroy_vector_agent(agent_id)

    now = DateTime.utc_now() |> DateTime.to_iso8601()
    debris_id = unique("debris")
    fingerprint = String.duplicate("f", 64)

    # Inject removable debris while fence is closed (simulates post-close debris).
    SQLiteRepo.query!(
      """
      UPDATE vector_agent_fences
      SET state = 'open', closed_at = NULL
      WHERE agent_id = ?
      """,
      [agent_id]
    )

    SQLiteRepo.query!(
      """
      INSERT INTO memory_embeddings (
        id, agent_id, content, content_hash, embedding,
        vector_protocol, source_namespace, source_key,
        generation, revision, tombstone, inserted_at, updated_at
      ) VALUES (
        ?, ?, '{}', ?, '[0.2]',
        'arbor_vector_store_v1', 'voice', 'debris',
        1, 1, 0, ?, ?
      )
      """,
      [debris_id, agent_id, String.duplicate("b", 64), now, now]
    )

    SQLiteRepo.query!(
      """
      INSERT INTO vector_operation_receipts (
        operation_fingerprint, agent_id, operation_kind,
        operation_json, operation_digest, receipt_json, receipt_digest, inserted_at
      ) VALUES (?, ?, 'insert', '{}', ?, '{}', ?, ?)
      """,
      [
        fingerprint,
        agent_id,
        String.duplicate("c", 64),
        String.duplicate("d", 64),
        now
      ]
    )

    SQLiteRepo.query!(
      """
      UPDATE vector_agent_fences
      SET state = 'closed', closed_at = CURRENT_TIMESTAMP
      WHERE agent_id = ?
      """,
      [agent_id]
    )

    assert :ok = Arbor.Persistence.destroy_vector_agent(agent_id)

    assert %{rows: [[0]]} =
             SQLiteRepo.query!(
               """
               SELECT COUNT(*) FROM memory_embeddings
               WHERE agent_id = ? AND vector_protocol = 'arbor_vector_store_v1'
               """,
               [agent_id]
             )

    assert %{rows: [[0]]} =
             SQLiteRepo.query!(
               "SELECT COUNT(*) FROM vector_operation_receipts WHERE agent_id = ?",
               [agent_id]
             )

    assert %{rows: [["closed"]]} =
             SQLiteRepo.query!(
               "SELECT state FROM vector_agent_fences WHERE agent_id = ?",
               [agent_id]
             )
  end

  test "destroy rollback is atomic and closed state survives repository restart" do
    database =
      Path.join(
        System.tmp_dir!(),
        "arbor-vector-restart-#{System.unique_integer([:positive])}.sqlite3"
      )

    original_backend =
      Application.get_env(:arbor_persistence, :vector_store_backend, :not_configured)

    original_repo = Application.get_env(:arbor_persistence, :vector_store_repo, :not_configured)

    start_supervised!(
      {RestartRepo,
       database: database,
       pool: DBConnection.ConnectionPool,
       pool_size: 1,
       busy_timeout: 5_000,
       journal_mode: :wal,
       custom_pragmas: [recursive_triggers: true]},
      id: :vector_restart_repo
    )

    on_exit(fn ->
      restore_env(:vector_store_backend, original_backend)
      restore_env(:vector_store_repo, original_repo)
      Enum.each([database, database <> "-shm", database <> "-wal"], &File.rm/1)
    end)

    create_legacy_table!(RestartRepo)
    migrate_vector_chain!(RestartRepo)

    Application.put_env(
      :arbor_persistence,
      :vector_store_backend,
      Arbor.Persistence.VectorStore.Ecto
    )

    Application.put_env(:arbor_persistence, :vector_store_repo, RestartRepo)

    agent_id = unique("agent")
    operation = insert_operation!(record!(agent_id, source_key: "rollback-destroy"))
    assert {:ok, _} = Arbor.Persistence.execute_vector_operation(agent_id, operation)

    Arbor.Persistence.VectorStore.Ecto.__set_post_destroy_residual_override__(true)

    try do
      assert {:error, :indeterminate} = Arbor.Persistence.destroy_vector_agent(agent_id)
    after
      Arbor.Persistence.VectorStore.Ecto.__clear_post_destroy_residual_override__()
    end

    assert %{rows: [[1]]} =
             RestartRepo.query!(
               """
               SELECT COUNT(*) FROM memory_embeddings
               WHERE agent_id = ? AND vector_protocol = 'arbor_vector_store_v1'
               """,
               [agent_id]
             )

    assert %{rows: [[1]]} =
             RestartRepo.query!(
               "SELECT COUNT(*) FROM vector_operation_receipts WHERE agent_id = ?",
               [agent_id]
             )

    assert %{rows: [["open"]]} =
             RestartRepo.query!(
               "SELECT state FROM vector_agent_fences WHERE agent_id = ?",
               [agent_id]
             )

    assert :ok = Arbor.Persistence.destroy_vector_agent(agent_id)

    # Dedicated RestartRepo only — never stop the setup_all shared SQLiteRepo.
    case stop_supervised(:vector_restart_repo) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    Process.sleep(50)

    start_supervised!(
      {RestartRepo,
       database: database,
       pool: DBConnection.ConnectionPool,
       pool_size: 1,
       busy_timeout: 5_000,
       journal_mode: :wal,
       custom_pragmas: [recursive_triggers: true]},
      restart: :temporary,
      id: :vector_restart_repo_reopened
    )

    Application.put_env(:arbor_persistence, :vector_store_repo, RestartRepo)

    assert %{rows: [["closed"]]} =
             RestartRepo.query!(
               "SELECT state FROM vector_agent_fences WHERE agent_id = ?",
               [agent_id]
             )

    assert {:error, :closed} = Arbor.Persistence.list_vector_records(agent_id)
  end

  test "fence migration refuses destructive rollback" do
    # Module is already loaded by setup_all's fence migration install.
    assert_raise RuntimeError, ~r/irreversible migration/, fn ->
      Arbor.Persistence.Repo.Migrations.CreateVectorAgentFences.down()
    end
  end

  test "fence agent_id DB constraint rejects empty and oversize identifiers" do
    assert_raise Exqlite.Error, fn ->
      SQLiteRepo.query!("""
      INSERT INTO vector_agent_fences (agent_id, state, closed_at, updated_at)
      VALUES ('', 'open', NULL, CURRENT_TIMESTAMP)
      """)
    end

    assert_raise Exqlite.Error, fn ->
      SQLiteRepo.query!("""
      INSERT INTO vector_agent_fences (agent_id, state, closed_at, updated_at)
      VALUES ('   ', 'open', NULL, CURRENT_TIMESTAMP)
      """)
    end

    oversize = String.duplicate("a", 257)

    assert_raise Exqlite.Error, fn ->
      SQLiteRepo.query!(
        """
        INSERT INTO vector_agent_fences (agent_id, state, closed_at, updated_at)
        VALUES (?, 'open', NULL, CURRENT_TIMESTAMP)
        """,
        [oversize]
      )
    end

    max_id = String.duplicate("b", 256)

    assert %{num_rows: 1} =
             SQLiteRepo.query!(
               """
               INSERT INTO vector_agent_fences (agent_id, state, closed_at, updated_at)
               VALUES (?, 'open', NULL, CURRENT_TIMESTAMP)
               """,
               [max_id]
             )

    # Multibyte byte-boundary: 128 two-byte codepoints (256 UTF-8 bytes) accepted;
    # 129 (258 bytes) rejected.
    two_byte = "é"
    assert byte_size(two_byte) == 2
    accepted = String.duplicate(two_byte, 128)
    rejected = String.duplicate(two_byte, 129)
    assert byte_size(accepted) == 256
    assert byte_size(rejected) == 258

    assert %{num_rows: 1} =
             SQLiteRepo.query!(
               """
               INSERT INTO vector_agent_fences (agent_id, state, closed_at, updated_at)
               VALUES (?, 'open', NULL, CURRENT_TIMESTAMP)
               """,
               [accepted]
             )

    assert_raise Exqlite.Error, fn ->
      SQLiteRepo.query!(
        """
        INSERT INTO vector_agent_fences (agent_id, state, closed_at, updated_at)
        VALUES (?, 'open', NULL, CURRENT_TIMESTAMP)
        """,
        [rejected]
      )
    end
  end

  test "fence state/closed_at coherence constraints are enforced" do
    assert_raise Exqlite.Error, fn ->
      SQLiteRepo.query!("""
      INSERT INTO vector_agent_fences (agent_id, state, closed_at, updated_at)
      VALUES ('coherent_bad_closed', 'closed', NULL, CURRENT_TIMESTAMP)
      """)
    end

    assert_raise Exqlite.Error, fn ->
      SQLiteRepo.query!("""
      INSERT INTO vector_agent_fences (agent_id, state, closed_at, updated_at)
      VALUES ('coherent_bad_open', 'open', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      """)
    end

    assert_raise Exqlite.Error, fn ->
      SQLiteRepo.query!("""
      INSERT INTO vector_agent_fences (agent_id, state, closed_at, updated_at)
      VALUES ('coherent_bad_destroying', 'destroying', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      """)
    end

    assert %{num_rows: 1} =
             SQLiteRepo.query!("""
             INSERT INTO vector_agent_fences (agent_id, state, closed_at, updated_at)
             VALUES ('coherent_ok_closed', 'closed', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
             """)

    assert %{num_rows: 1} =
             SQLiteRepo.query!("""
             INSERT INTO vector_agent_fences (agent_id, state, closed_at, updated_at)
             VALUES ('coherent_ok_open', 'open', NULL, CURRENT_TIMESTAMP)
             """)
  end

  test "ordinary ops fail closed while fence is destroying; destroy retry closes", %{
    agent_id: agent_id
  } do
    operation = insert_operation!(record!(agent_id, source_key: "sqlite-destroying"))
    assert {:ok, _} = Arbor.Persistence.execute_vector_operation(agent_id, operation)

    SQLiteRepo.query!(
      """
      UPDATE vector_agent_fences
      SET state = 'destroying', closed_at = NULL
      WHERE agent_id = ?
      """,
      [agent_id]
    )

    assert {:error, :closed} =
             Arbor.Persistence.execute_vector_operation(
               agent_id,
               insert_operation!(record!(agent_id, source_key: "while-destroying"))
             )

    assert {:error, :closed} =
             Arbor.Persistence.fetch_vector_record(agent_id, "voice", "sqlite-destroying")

    assert {:error, :closed} = Arbor.Persistence.list_vector_records(agent_id)

    assert {:error, :closed} =
             Arbor.Persistence.reconcile_vector_operation(agent_id, operation)

    assert :ok = Arbor.Persistence.destroy_vector_agent(agent_id)

    assert %{rows: [[0]]} =
             SQLiteRepo.query!(
               """
               SELECT COUNT(*) FROM memory_embeddings
               WHERE agent_id = ? AND vector_protocol = 'arbor_vector_store_v1'
               """,
               [agent_id]
             )

    assert %{rows: [[0]]} =
             SQLiteRepo.query!(
               "SELECT COUNT(*) FROM vector_operation_receipts WHERE agent_id = ?",
               [agent_id]
             )

    assert %{rows: [["closed", closed_at]]} =
             SQLiteRepo.query!(
               "SELECT state, closed_at FROM vector_agent_fences WHERE agent_id = ?",
               [agent_id]
             )

    assert is_binary(closed_at) and closed_at != ""
  end

  test "security regression: fence migration fails closed on pre-existing table collision" do
    database =
      Path.join(
        System.tmp_dir!(),
        "arbor-vector-fence-table-collision-#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!(
      {CollisionRepo,
       database: database,
       pool: DBConnection.ConnectionPool,
       pool_size: 1,
       busy_timeout: 5_000,
       custom_pragmas: [recursive_triggers: true]},
      id: :sqlite_fence_table_collision_repo
    )

    on_exit(fn ->
      Enum.each([database, database <> "-shm", database <> "-wal"], &File.rm/1)
    end)

    create_legacy_table!(CollisionRepo)
    migrate_pre_fence_chain!(CollisionRepo)

    CollisionRepo.query!("CREATE TABLE vector_agent_fences (agent_id TEXT PRIMARY KEY)")

    error =
      try do
        Ecto.Migrator.up(
          CollisionRepo,
          @fence_migration_version,
          Arbor.Persistence.Repo.Migrations.CreateVectorAgentFences,
          log: false
        )

        flunk("expected table collision to fail closed")
      rescue
        e -> e
      end

    assert Exception.message(error) =~ ~r/already exists|table.*exists/i

    # Wrong pre-existing definition retained (single column only).
    columns =
      CollisionRepo.query!("SELECT name FROM pragma_table_info('vector_agent_fences')").rows
      |> List.flatten()

    assert columns == ["agent_id"]
  end

  test "security regression: fence migration fails closed on pre-existing trigger collision" do
    database =
      Path.join(
        System.tmp_dir!(),
        "arbor-vector-fence-trigger-collision-#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!(
      {CollisionRepo,
       database: database,
       pool: DBConnection.ConnectionPool,
       pool_size: 1,
       busy_timeout: 5_000,
       custom_pragmas: [recursive_triggers: true]},
      id: :sqlite_fence_trigger_collision_repo
    )

    on_exit(fn ->
      Enum.each([database, database <> "-shm", database <> "-wal"], &File.rm/1)
    end)

    create_legacy_table!(CollisionRepo)
    migrate_pre_fence_chain!(CollisionRepo)

    CollisionRepo.query!("""
    CREATE TRIGGER vector_operation_receipts_admit_insert
    BEFORE INSERT ON vector_operation_receipts
    FOR EACH ROW
    BEGIN
      SELECT RAISE(ABORT, 'dummy collision trigger');
    END
    """)

    error =
      try do
        Ecto.Migrator.up(
          CollisionRepo,
          @fence_migration_version,
          Arbor.Persistence.Repo.Migrations.CreateVectorAgentFences,
          log: false
        )

        flunk("expected trigger collision to fail closed")
      rescue
        e -> e
      end

    assert Exception.message(error) =~ ~r/already exists|trigger.*exists/i

    assert %{rows: [[1]]} =
             CollisionRepo.query!("""
             SELECT COUNT(*)
             FROM sqlite_master
             WHERE type = 'trigger'
               AND name = 'vector_operation_receipts_admit_insert'
               AND sql LIKE '%dummy collision trigger%'
             """)
  end

  test "fence migration backfills strict V1 and receipt agents, excludes pure legacy" do
    database =
      Path.join(
        System.tmp_dir!(),
        "arbor-vector-fence-backfill-#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!(
      {BackfillRepo,
       database: database,
       pool: DBConnection.ConnectionPool,
       pool_size: 1,
       busy_timeout: 5_000,
       custom_pragmas: [recursive_triggers: true]},
      id: :sqlite_backfill_repo
    )

    on_exit(fn ->
      Enum.each([database, database <> "-shm", database <> "-wal"], &File.rm/1)
    end)

    create_legacy_table!(BackfillRepo)

    assert :ok ==
             Ecto.Migrator.up(BackfillRepo, @migration_version, @migration_module, log: false)

    assert :ok ==
             Ecto.Migrator.up(
               BackfillRepo,
               @widen_migration_version,
               @widen_migration_module,
               log: false
             )

    assert :ok ==
             Ecto.Migrator.up(
               BackfillRepo,
               @isolation_migration_version,
               @isolation_migration_module,
               log: false
             )

    assert :ok ==
             Ecto.Migrator.up(
               BackfillRepo,
               @receipt_guard_migration_version,
               Arbor.Persistence.Repo.Migrations.HardenVectorReceiptInserts,
               log: false
             )

    assert :ok ==
             Ecto.Migrator.up(
               BackfillRepo,
               @receipt_rowid_guard_migration_version,
               Arbor.Persistence.Repo.Migrations.HardenVectorReceiptRowids,
               log: false
             )

    now = DateTime.utc_now() |> DateTime.to_iso8601()
    strict_agent = unique("strict")
    receipt_agent = unique("receipt")
    legacy_agent = unique("legacy")

    BackfillRepo.query!(
      """
      INSERT INTO memory_embeddings (
        id, agent_id, content, content_hash, embedding,
        vector_protocol, source_namespace, source_key,
        generation, revision, tombstone, inserted_at, updated_at
      ) VALUES (
        ?, ?, '{}', ?, '[0.1]',
        'arbor_vector_store_v1', 'voice', 'strict-key',
        1, 1, 0, ?, ?
      )
      """,
      [unique("vec"), strict_agent, String.duplicate("a", 64), now, now]
    )

    BackfillRepo.query!(
      """
      INSERT INTO memory_embeddings (
        id, agent_id, content, content_hash, embedding,
        vector_protocol, source_namespace, source_key,
        generation, revision, tombstone, inserted_at, updated_at
      ) VALUES (
        ?, ?, '{}', ?, '[0.2]',
        NULL, NULL, NULL,
        NULL, NULL, NULL, ?, ?
      )
      """,
      [unique("legacy"), legacy_agent, String.duplicate("b", 64), now, now]
    )

    # Receipt-only tenant (no strict V1 row) must still backfill an open fence.
    # Fence table does not exist yet, so insert admission triggers are not installed.
    # Insert receipts before fence migration; Harden* migrations only add insert conflict
    # guards, not fence-open admission (that arrives with CreateVectorAgentFences).
    BackfillRepo.query!(
      """
      INSERT INTO vector_operation_receipts (
        operation_fingerprint, agent_id, operation_kind,
        operation_json, operation_digest, receipt_json, receipt_digest, inserted_at
      ) VALUES (?, ?, 'insert', '{}', ?, '{}', ?, ?)
      """,
      [
        String.duplicate("c", 64),
        receipt_agent,
        String.duplicate("d", 64),
        String.duplicate("e", 64),
        now
      ]
    )

    assert :ok ==
             Ecto.Migrator.up(
               BackfillRepo,
               @fence_migration_version,
               Arbor.Persistence.Repo.Migrations.CreateVectorAgentFences,
               log: false
             )

    assert %{rows: [[1]]} =
             BackfillRepo.query!(
               "SELECT COUNT(*) FROM vector_agent_fences WHERE agent_id = ? AND state = 'open'",
               [strict_agent]
             )

    assert %{rows: [[1]]} =
             BackfillRepo.query!(
               "SELECT COUNT(*) FROM vector_agent_fences WHERE agent_id = ? AND state = 'open'",
               [receipt_agent]
             )

    assert %{rows: [[0]]} =
             BackfillRepo.query!(
               "SELECT COUNT(*) FROM vector_agent_fences WHERE agent_id = ?",
               [legacy_agent]
             )
  end

  test "raw receipt insert is rejected when fence is closed", %{agent_id: agent_id} do
    assert :ok = Arbor.Persistence.destroy_vector_agent(agent_id)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    assert_raise Exqlite.Error, ~r/fence not open/, fn ->
      SQLiteRepo.query!(
        """
        INSERT INTO vector_operation_receipts (
          operation_fingerprint, agent_id, operation_kind,
          operation_json, operation_digest, receipt_json, receipt_digest, inserted_at
        ) VALUES (?, ?, 'insert', '{}', ?, '{}', ?, ?)
        """,
        [
          String.duplicate("1", 64),
          agent_id,
          String.duplicate("2", 64),
          String.duplicate("3", 64),
          now
        ]
      )
    end
  end

  test "invalid destroy inputs stay normalized at the boundary" do
    assert {:error, :invalid_request} = Arbor.Persistence.destroy_vector_agent("")
    assert {:error, :invalid_request} = Arbor.Persistence.destroy_vector_agent(nil)
    assert {:error, :invalid_request} = Arbor.Persistence.destroy_vector_agent("agent", bad: true)

    assert {:error, :unsupported} =
             with_backend(Arbor.Persistence.VectorStore.Unsupported, fn ->
               Arbor.Persistence.destroy_vector_agent(unique("agent"))
             end)
  end

  test "indeterminate destroy residual override normalizes", %{agent_id: agent_id} do
    Arbor.Persistence.VectorStore.Ecto.__set_post_destroy_residual_override__(true)

    try do
      assert {:error, :indeterminate} = Arbor.Persistence.destroy_vector_agent(agent_id)
    after
      Arbor.Persistence.VectorStore.Ecto.__clear_post_destroy_residual_override__()
    end
  end

  test "security regression: SQLite replace cannot bypass immutable receipts with recursive triggers off",
       %{
         agent_id: agent_id,
         database_path: database
       } do
    operation = insert_operation!(record!(agent_id, source_key: "immutable-replace-ledger"))

    assert {:ok, original_receipt} =
             Arbor.Persistence.execute_vector_operation(agent_id, operation)

    {:ok, connection} = Exqlite.Sqlite3.open(database)

    try do
      assert :ok = Exqlite.Sqlite3.execute(connection, "PRAGMA recursive_triggers = OFF")
      assert 0 == sqlite_scalar!(connection, "PRAGMA recursive_triggers")

      replace_sql = """
      INSERT OR REPLACE INTO vector_operation_receipts (
        operation_fingerprint, agent_id, operation_kind,
        operation_json, operation_digest, receipt_json, receipt_digest, inserted_at
      )
      SELECT operation_fingerprint, agent_id, operation_kind,
             operation_json, operation_digest, receipt_json,
             '#{String.duplicate("0", 64)}', inserted_at
      FROM vector_operation_receipts
      WHERE operation_fingerprint = '#{operation.fingerprint}'
      """

      assert {:error, reason} = Exqlite.Sqlite3.execute(connection, replace_sql)
      assert to_string(reason) =~ "vector_operation_receipts is immutable"
    after
      Exqlite.Sqlite3.close(connection)
    end

    assert {:ok, ^original_receipt} =
             Arbor.Persistence.reconcile_vector_operation(agent_id, operation)
  end

  test "security regression: SQLite rowid replace cannot move an immutable receipt", %{
    agent_id: agent_id,
    database_path: database
  } do
    operation = insert_operation!(record!(agent_id, source_key: "immutable-rowid-ledger"))

    assert {:ok, original_receipt} =
             Arbor.Persistence.execute_vector_operation(agent_id, operation)

    {:ok, connection} = Exqlite.Sqlite3.open(database)

    try do
      assert :ok = Exqlite.Sqlite3.execute(connection, "PRAGMA recursive_triggers = OFF")
      assert 0 == sqlite_scalar!(connection, "PRAGMA recursive_triggers")

      exact_retry_sql = """
      INSERT INTO vector_operation_receipts (
        operation_fingerprint, agent_id, operation_kind,
        operation_json, operation_digest, receipt_json, receipt_digest, inserted_at
      )
      SELECT operation_fingerprint, agent_id, operation_kind,
             operation_json, operation_digest, receipt_json, receipt_digest, inserted_at
      FROM vector_operation_receipts
      WHERE operation_fingerprint = '#{operation.fingerprint}'
      ON CONFLICT(operation_fingerprint) DO NOTHING
      """

      assert :ok = Exqlite.Sqlite3.execute(connection, exact_retry_sql)

      replacement_fingerprint = String.duplicate("e", 64)

      rowid_replace_sql = """
      INSERT OR REPLACE INTO vector_operation_receipts (
        rowid, operation_fingerprint, agent_id, operation_kind,
        operation_json, operation_digest, receipt_json, receipt_digest, inserted_at
      )
      SELECT rowid, '#{replacement_fingerprint}', agent_id, operation_kind,
             operation_json, operation_digest, receipt_json,
             '#{String.duplicate("0", 64)}', inserted_at
      FROM vector_operation_receipts
      WHERE operation_fingerprint = '#{operation.fingerprint}'
      """

      assert {:error, reason} = Exqlite.Sqlite3.execute(connection, rowid_replace_sql)
      assert to_string(reason) =~ "vector_operation_receipts is immutable"
    after
      Exqlite.Sqlite3.close(connection)
    end

    assert {:ok, ^original_receipt} =
             Arbor.Persistence.reconcile_vector_operation(agent_id, operation)
  end

  defp maybe_install_receipt_insert_guard! do
    migrations = [
      {@receipt_guard_migration_version, @receipt_guard_migration_file},
      {@receipt_rowid_guard_migration_version, @receipt_rowid_guard_migration_file}
    ]

    Enum.each(migrations, fn {version, file} ->
      if File.exists?(file) do
        [{module, _bytecode}] = Code.require_file(file)
        assert :ok == Ecto.Migrator.up(SQLiteRepo, version, module, log: false)
      end
    end)
  end

  defp maybe_install_fence_migration! do
    if File.exists?(@fence_migration_file) do
      _ = Code.require_file(@fence_migration_file)

      assert :ok ==
               Ecto.Migrator.up(
                 SQLiteRepo,
                 @fence_migration_version,
                 Arbor.Persistence.Repo.Migrations.CreateVectorAgentFences,
                 log: false
               )
    end
  end

  defp migrate_pre_fence_chain!(repo) do
    assert :ok == Ecto.Migrator.up(repo, @migration_version, @migration_module, log: false)

    assert :ok ==
             Ecto.Migrator.up(repo, @widen_migration_version, @widen_migration_module, log: false)

    assert :ok ==
             Ecto.Migrator.up(
               repo,
               @isolation_migration_version,
               @isolation_migration_module,
               log: false
             )

    if File.exists?(@receipt_guard_migration_file) do
      _ = Code.require_file(@receipt_guard_migration_file)

      assert :ok ==
               Ecto.Migrator.up(
                 repo,
                 @receipt_guard_migration_version,
                 Arbor.Persistence.Repo.Migrations.HardenVectorReceiptInserts,
                 log: false
               )
    end

    if File.exists?(@receipt_rowid_guard_migration_file) do
      _ = Code.require_file(@receipt_rowid_guard_migration_file)

      assert :ok ==
               Ecto.Migrator.up(
                 repo,
                 @receipt_rowid_guard_migration_version,
                 Arbor.Persistence.Repo.Migrations.HardenVectorReceiptRowids,
                 log: false
               )
    end
  end

  defp migrate_vector_chain!(repo) do
    migrate_pre_fence_chain!(repo)
    _ = Code.require_file(@fence_migration_file)

    assert :ok ==
             Ecto.Migrator.up(
               repo,
               @fence_migration_version,
               Arbor.Persistence.Repo.Migrations.CreateVectorAgentFences,
               log: false
             )
  end

  defp with_backend(backend, fun) do
    original = Application.get_env(:arbor_persistence, :vector_store_backend, :not_configured)
    Application.put_env(:arbor_persistence, :vector_store_backend, backend)

    try do
      fun.()
    after
      restore_env(:vector_store_backend, original)
    end
  end

  defp search_opts(overrides \\ []) do
    Keyword.merge(
      [
        model_id: "provider/model-v1",
        dimensions: VectorRecord.dimensions(),
        encoding: VectorRecord.encoding(),
        category: "voice",
        source_namespace: "voice",
        threshold: nil,
        limit: 20
      ],
      overrides
    )
  end

  defp ensure_open_fence!(agent_id) do
    SQLiteRepo.query!(
      """
      INSERT OR IGNORE INTO vector_agent_fences (agent_id, state, closed_at, updated_at)
      VALUES (?, 'open', NULL, CURRENT_TIMESTAMP)
      """,
      [agent_id]
    )
  end

  defp sqlite_scalar!(connection, sql) do
    {:ok, statement} = Exqlite.Sqlite3.prepare(connection, sql)

    try do
      {:row, [value]} = Exqlite.Sqlite3.step(connection, statement)
      value
    after
      Exqlite.Sqlite3.release(connection, statement)
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

  defp insert_forged_ledger!(operation, operation_json, receipt_json) do
    agent_id = VectorOperation.agent_id(operation)
    ensure_open_fence!(agent_id)

    SQLiteRepo.query!(
      """
      INSERT INTO vector_operation_receipts (
        operation_fingerprint, agent_id, operation_kind,
        operation_json, operation_digest, receipt_json, receipt_digest, inserted_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        operation.fingerprint,
        agent_id,
        Atom.to_string(operation.kind),
        operation_json,
        Codec.digest(operation_json),
        receipt_json,
        Codec.digest(receipt_json),
        DateTime.utc_now() |> DateTime.to_iso8601()
      ]
    )
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

  defp execute_and_discard_response(agent_id, operation) do
    case Arbor.Persistence.execute_vector_operation(agent_id, operation) do
      {:ok, _discarded_receipt} -> :response_lost
      error -> error
    end
  end

  defp restore_env(key, :not_configured), do: Application.delete_env(:arbor_persistence, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_persistence, key, value)
end
