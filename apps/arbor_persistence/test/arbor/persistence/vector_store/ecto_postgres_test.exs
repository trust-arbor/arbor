defmodule Arbor.Persistence.VectorStore.EctoPostgresTest do
  use Arbor.Persistence.DatabaseCase, async: false

  alias Arbor.Contracts.Persistence.{VectorMatch, VectorOperation, VectorRecord}

  @moduletag :database
  @moduletag :integration
  @moduletag :postgres

  @fence_migration_version 20_260_807_000_001
  @fence_migration_file Path.expand(
                          "../../../../priv/repo/migrations/20260807000001_create_vector_agent_fences.exs",
                          __DIR__
                        )

  Code.require_file(@fence_migration_file)

  defmodule FenceMigrationRepo do
    use Ecto.Repo,
      otp_app: :arbor_persistence,
      adapter: Ecto.Adapters.Postgres
  end

  if Arbor.Persistence.Repo.__adapter__() != Ecto.Adapters.Postgres do
    @moduletag skip: "PostgreSQL vector-store coverage requires ARBOR_DB=postgres"
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

    Application.put_env(:arbor_persistence, :vector_store_repo, Arbor.Persistence.Repo)

    on_exit(fn ->
      restore_env(:vector_store_backend, original_backend)
      restore_env(:vector_store_repo, original_repo)
    end)

    {:ok, agent_id: unique("agent")}
  end

  use Arbor.Persistence.VectorStore.LegacyIsolationConformance,
    repo: Arbor.Persistence.Repo,
    legacy_mutations: true

  test "regression: pgvector search returns the exact authoritative row id", %{
    agent_id: agent_id
  } do
    target_id = unique("authoritative_row")
    query_vector = unit_vector(0)

    target =
      record!(agent_id,
        id: target_id,
        source_key: "target",
        vector: query_vector
      )

    distractor = record!(agent_id, source_key: "distractor", vector: unit_vector(1))
    wrong_model = record!(agent_id, source_key: "wrong-model", model_id: "provider/model-v2")
    wrong_category = record!(agent_id, source_key: "wrong-category", category: "other")
    wrong_dimensions = record!(agent_id, source_key: "wrong-dimensions")
    wrong_encoding = record!(agent_id, source_key: "wrong-encoding")
    foreign = record!(unique("agent"), source_key: "foreign", vector: query_vector)
    tombstone = record!(agent_id, source_key: "tombstone", vector: query_vector)

    for record <- [
          target,
          distractor,
          wrong_model,
          wrong_category,
          wrong_dimensions,
          wrong_encoding,
          foreign,
          tombstone
        ] do
      operation = insert_operation!(record)

      assert {:ok, _receipt} =
               Arbor.Persistence.execute_vector_operation(record.agent_id, operation)
    end

    Arbor.Persistence.Repo.query!(
      "UPDATE memory_embeddings SET dimensions = 767 WHERE id = $1",
      [wrong_dimensions.id]
    )

    Arbor.Persistence.Repo.query!(
      "UPDATE memory_embeddings SET encoding = 'other' WHERE id = $1",
      [wrong_encoding.id]
    )

    tombstone_delete = operation!(:delete, fetch!(agent_id, "tombstone"))

    assert {:ok, _deleted} =
             Arbor.Persistence.execute_vector_operation(agent_id, tombstone_delete)

    assert {:ok, [%VectorMatch{record: matched}]} =
             Arbor.Persistence.search_vector_records(
               agent_id,
               query_vector,
               search_opts(limit: 1)
             )

    assert matched.id == target_id
    assert matched.id != matched.payload_digest
    assert matched.id != matched.vector_digest
    assert matched.agent_id == agent_id
    assert matched.source_key == "target"
  end

  test "PostgreSQL search fails the whole read when any selected durable row is malformed", %{
    agent_id: agent_id
  } do
    valid = record!(agent_id, source_key: "valid", vector: unit_vector(0))
    malformed = record!(agent_id, source_key: "malformed", vector: unit_vector(1))

    for record <- [valid, malformed] do
      assert {:ok, _receipt} =
               Arbor.Persistence.execute_vector_operation(agent_id, insert_operation!(record))
    end

    Arbor.Persistence.Repo.query!(
      "UPDATE memory_embeddings SET vector_digest = $1 WHERE id = $2",
      [String.duplicate("0", 64), malformed.id]
    )

    assert {:error, :backend_failure} =
             Arbor.Persistence.search_vector_records(
               agent_id,
               unit_vector(0),
               search_opts(limit: 10)
             )
  end

  test "security regression: PostgreSQL search rejects oversized and deeply nested payload JSON" do
    limits = VectorRecord.limits().payload
    oversized = "\"" <> String.duplicate("x", limits.max_payload_bytes) <> "\""

    deeply_nested =
      String.duplicate("[", limits.max_depth + 2) <>
        "0" <> String.duplicate("]", limits.max_depth + 2)

    for {suffix, corrupt_json} <- [oversized: oversized, deep: deeply_nested] do
      agent_id = unique("agent_#{suffix}")
      record = record!(agent_id, source_key: "corrupt", vector: unit_vector(0))

      assert {:ok, _receipt} =
               Arbor.Persistence.execute_vector_operation(agent_id, insert_operation!(record))

      Arbor.Persistence.Repo.query!(
        "UPDATE memory_embeddings SET canonical_payload = $1, content = $1 WHERE id = $2",
        [corrupt_json, record.id]
      )

      assert {:error, :backend_failure} =
               Arbor.Persistence.search_vector_records(
                 agent_id,
                 unit_vector(0),
                 search_opts(limit: 10)
               )
    end
  end

  test "PostgreSQL search supports optional namespace, category, threshold, and mixed-category recall",
       %{
         agent_id: agent_id
       } do
    query_vector = unit_vector(0)

    goal =
      record!(agent_id,
        source_key: "goal",
        category: "goal",
        source_namespace: "voice",
        vector: query_vector
      )

    note =
      record!(agent_id,
        source_key: "note",
        category: "note",
        source_namespace: "voice",
        vector: unit_vector(0) |> List.replace_at(1, 0.01)
      )

    other_ns =
      record!(agent_id,
        source_key: "other-ns",
        category: "goal",
        source_namespace: "memory",
        vector: query_vector
      )

    distant =
      record!(agent_id,
        source_key: "distant",
        category: "goal",
        source_namespace: "voice",
        vector: unit_vector(1)
      )

    foreign = record!(unique("agent"), source_key: "foreign", vector: query_vector)
    tombstone = record!(agent_id, source_key: "tombstone", vector: query_vector)
    wrong_model = record!(agent_id, source_key: "wrong-model", model_id: "provider/model-v2")

    for record <- [goal, note, other_ns, distant, foreign, tombstone, wrong_model] do
      assert {:ok, _receipt} =
               Arbor.Persistence.execute_vector_operation(
                 record.agent_id,
                 insert_operation!(record)
               )
    end

    tombstone_delete = operation!(:delete, fetch!(agent_id, "tombstone"))

    assert {:ok, _deleted} =
             Arbor.Persistence.execute_vector_operation(agent_id, tombstone_delete)

    assert {:ok, matches} =
             Arbor.Persistence.search_vector_records(
               agent_id,
               query_vector,
               model_id: "provider/model-v1",
               dimensions: VectorRecord.dimensions(),
               encoding: VectorRecord.encoding(),
               source_namespace: "voice",
               limit: 10
             )

    ids = Enum.map(matches, & &1.record.id)
    assert goal.id in ids
    assert note.id in ids
    refute other_ns.id in ids
    refute foreign.id in ids
    refute wrong_model.id in ids
    refute tombstone.id in ids

    goal_id = goal.id
    distant_id = distant.id

    assert {:ok, [%VectorMatch{record: %{id: ^goal_id}} | _]} =
             Arbor.Persistence.search_vector_records(
               agent_id,
               query_vector,
               search_opts(category: "goal", source_namespace: "voice", limit: 10)
             )

    assert {:ok, category_filtered} =
             Arbor.Persistence.search_vector_records(
               agent_id,
               query_vector,
               search_opts(category: "goal", source_namespace: "voice", limit: 10)
             )

    refute Enum.any?(category_filtered, &(&1.record.category == "note"))

    assert {:ok, high} =
             Arbor.Persistence.search_vector_records(
               agent_id,
               query_vector,
               search_opts(
                 category: "goal",
                 source_namespace: "voice",
                 threshold: 0.99,
                 limit: 10
               )
             )

    high_ids = Enum.map(high, & &1.record.id)
    assert goal_id in high_ids
    refute distant_id in high_ids

    assert {:ok, unthresholded} =
             Arbor.Persistence.search_vector_records(
               agent_id,
               query_vector,
               search_opts(category: "goal", source_namespace: "voice", limit: 10)
             )

    assert distant_id in Enum.map(unthresholded, & &1.record.id)

    # Exact-threshold retention: identical vectors yield similarity 1.0; threshold 1.0 keeps them.
    assert {:ok, exact_threshold} =
             Arbor.Persistence.search_vector_records(
               agent_id,
               query_vector,
               search_opts(
                 category: "goal",
                 source_namespace: "voice",
                 threshold: 1.0,
                 limit: 10
               )
             )

    exact_ids = Enum.map(exact_threshold, & &1.record.id)
    assert goal_id in exact_ids
    refute distant_id in exact_ids
    assert Enum.all?(exact_threshold, &(&1.similarity >= 1.0))

    # Scopes apply before nearest-neighbor limit: out-of-scope exact match must not win limit:1.
    assert {:ok, [%VectorMatch{record: limited}]} =
             Arbor.Persistence.search_vector_records(
               agent_id,
               query_vector,
               search_opts(category: "goal", source_namespace: "voice", limit: 1)
             )

    assert limited.id == goal_id
    assert limited.source_namespace == "voice"

    assert {:ok, _} =
             Arbor.Persistence.search_vector_records(
               agent_id,
               query_vector,
               search_opts(limit: 1000)
             )
  end

  test "PostgreSQL search emits a single pgvector scoring expression under threshold", %{
    agent_id: agent_id
  } do
    query_vector = unit_vector(0)
    record = record!(agent_id, source_key: "scored", vector: query_vector)

    assert {:ok, _receipt} =
             Arbor.Persistence.execute_vector_operation(agent_id, insert_operation!(record))

    parent = self()
    handler_id = "vector-search-single-score-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        Arbor.Persistence.Repo.config()[:telemetry_prefix] ++ [:query],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:ecto_query, metadata[:query]})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, [%VectorMatch{record: %{id: matched_id}}]} =
             Arbor.Persistence.search_vector_records(
               agent_id,
               query_vector,
               search_opts(threshold: 0.5, limit: 5)
             )

    assert matched_id == record.id

    search_sql =
      receive_ecto_search_sql(deadline: System.monotonic_time(:millisecond) + 2_000)

    assert search_sql =~ "<=>"
    assert length(String.split(search_sql, "<=>")) - 1 == 1

    assert String.contains?(String.upcase(search_sql), "CAST") or
             String.contains?(search_sql, "::real") or
             String.contains?(String.downcase(search_sql), " as real")
  end

  test "PostgreSQL rejects zero-norm queries and searches ordinary signed vectors", %{
    agent_id: agent_id
  } do
    zero_vector = List.duplicate(0.0, VectorRecord.dimensions())

    assert {:error, :invalid_request} =
             Arbor.Persistence.search_vector_records(
               agent_id,
               zero_vector,
               search_opts(limit: 1)
             )

    signed_vector = [-1.0, 1.0 | List.duplicate(0.0, 766)]
    signed_record = record!(agent_id, source_key: "signed", vector: signed_vector)

    assert {:ok, _receipt} =
             Arbor.Persistence.execute_vector_operation(
               agent_id,
               insert_operation!(signed_record)
             )

    assert {:ok, [%VectorMatch{record: %{id: signed_id}}]} =
             Arbor.Persistence.search_vector_records(
               agent_id,
               signed_vector,
               search_opts(limit: 1)
             )

    assert signed_id == signed_record.id
  end

  test "PostgreSQL stores the full 256-byte contract-valid tenant id" do
    agent_id = String.duplicate("a", VectorRecord.limits().agent_id_bytes)
    record = record!(agent_id, source_key: unique("max-agent"))
    operation = insert_operation!(record)

    assert byte_size(agent_id) == 256
    assert {:ok, receipt} = Arbor.Persistence.execute_vector_operation(agent_id, operation)
    receipt_record = receipt.record

    assert {:ok, ^receipt_record} =
             Arbor.Persistence.fetch_vector_record(
               agent_id,
               record.source_namespace,
               record.source_key
             )

    assert %{rows: [["memory_embeddings", 256], ["vector_operation_receipts", 256]]} =
             Arbor.Persistence.Repo.query!("""
             SELECT table_name, character_maximum_length
             FROM information_schema.columns
             WHERE table_schema = current_schema()
               AND column_name = 'agent_id'
               AND table_name IN ('memory_embeddings', 'vector_operation_receipts')
             ORDER BY table_name
             """)
  end

  test "destroy closes tenant, preserves other tenants, and ordinary ops fail closed", %{
    agent_id: agent_id
  } do
    other_id = unique("agent")
    target = insert_operation!(record!(agent_id, source_key: "pg-destroy-target"))
    other = insert_operation!(record!(other_id, source_key: "pg-destroy-other"))

    assert {:ok, _} = Arbor.Persistence.execute_vector_operation(agent_id, target)
    assert {:ok, _} = Arbor.Persistence.execute_vector_operation(other_id, other)
    assert :ok = Arbor.Persistence.destroy_vector_agent(agent_id)

    assert %{rows: [[0]]} =
             Arbor.Persistence.Repo.query!(
               """
               SELECT COUNT(*) FROM memory_embeddings
               WHERE agent_id = $1 AND vector_protocol = 'arbor_vector_store_v1'
               """,
               [agent_id]
             )

    assert %{rows: [[0]]} =
             Arbor.Persistence.Repo.query!(
               "SELECT COUNT(*) FROM vector_operation_receipts WHERE agent_id = $1",
               [agent_id]
             )

    assert %{rows: [[1]]} =
             Arbor.Persistence.Repo.query!(
               """
               SELECT COUNT(*) FROM memory_embeddings
               WHERE agent_id = $1 AND vector_protocol = 'arbor_vector_store_v1'
               """,
               [other_id]
             )

    assert %{rows: [["closed"]]} =
             Arbor.Persistence.Repo.query!(
               "SELECT state FROM vector_agent_fences WHERE agent_id = $1",
               [agent_id]
             )

    assert {:error, :closed} =
             Arbor.Persistence.execute_vector_operation(
               agent_id,
               insert_operation!(record!(agent_id, source_key: "after-close"))
             )

    assert {:error, :closed} =
             Arbor.Persistence.search_vector_records(
               agent_id,
               unit_vector(0),
               search_opts(limit: 1)
             )

    assert {:ok, _} =
             Arbor.Persistence.list_vector_records(other_id)
  end

  test "destroy records actual UTC closure time independent of session timezone", %{
    agent_id: agent_id
  } do
    operation = insert_operation!(record!(agent_id, source_key: "pg-destroy-timestamp"))
    assert {:ok, _} = Arbor.Persistence.execute_vector_operation(agent_id, operation)

    Arbor.Persistence.Repo.query!("SET LOCAL TIME ZONE 'America/Los_Angeles'")
    before_destroy = DateTime.utc_now() |> DateTime.to_naive()
    assert :ok = Arbor.Persistence.destroy_vector_agent(agent_id)
    after_destroy = DateTime.utc_now() |> DateTime.to_naive()

    assert %{rows: [["closed", closed_at]]} =
             Arbor.Persistence.Repo.query!(
               "SELECT state, closed_at FROM vector_agent_fences WHERE agent_id = $1",
               [agent_id]
             )

    assert NaiveDateTime.compare(closed_at, before_destroy) in [:eq, :gt]
    assert NaiveDateTime.compare(closed_at, after_destroy) in [:eq, :lt]
  end

  test "security regression: public execute fails closed on destroyed PostgreSQL tenant", %{
    agent_id: agent_id
  } do
    operation = insert_operation!(record!(agent_id, source_key: "pg-security-closed"))
    assert {:ok, _} = Arbor.Persistence.execute_vector_operation(agent_id, operation)
    assert :ok = Arbor.Persistence.destroy_vector_agent(agent_id)

    assert {:error, :closed} =
             Arbor.Persistence.execute_vector_operation(
               agent_id,
               insert_operation!(record!(agent_id, source_key: "pg-security-closed-retry"))
             )
  end

  test "PostgreSQL receipt insert trigger rejects closed fence and delete only while destroying",
       %{agent_id: agent_id} do
    operation = insert_operation!(record!(agent_id, source_key: "pg-trigger"))
    assert {:ok, _} = Arbor.Persistence.execute_vector_operation(agent_id, operation)
    assert :ok = Arbor.Persistence.destroy_vector_agent(agent_id)

    assert_postgres_error!(
      fn ->
        Arbor.Persistence.Repo.query!(
          """
          INSERT INTO vector_operation_receipts (
            operation_fingerprint, agent_id, operation_kind,
            operation_json, operation_digest, receipt_json, receipt_digest, inserted_at
          ) VALUES ($1, $2, 'insert', '{}', $3, '{}', $4, CURRENT_TIMESTAMP)
          """,
          [
            String.duplicate("a", 64),
            agent_id,
            String.duplicate("b", 64),
            String.duplicate("c", 64)
          ]
        )
      end,
      code: :integrity_constraint_violation,
      message: ~r/fence not open/i
    )

    open_agent = unique("agent")

    Arbor.Persistence.Repo.query!(
      """
      INSERT INTO vector_agent_fences (agent_id, state, closed_at, updated_at)
      VALUES ($1, 'open', NULL, CURRENT_TIMESTAMP)
      ON CONFLICT (agent_id) DO NOTHING
      """,
      [open_agent]
    )

    Arbor.Persistence.Repo.query!(
      """
      INSERT INTO vector_operation_receipts (
        operation_fingerprint, agent_id, operation_kind,
        operation_json, operation_digest, receipt_json, receipt_digest, inserted_at
      ) VALUES ($1, $2, 'insert', '{}', $3, '{}', $4, CURRENT_TIMESTAMP)
      """,
      [
        String.duplicate("d", 64),
        open_agent,
        String.duplicate("e", 64),
        String.duplicate("f", 64)
      ]
    )

    assert_postgres_error!(
      fn ->
        Arbor.Persistence.Repo.query!(
          "DELETE FROM vector_operation_receipts WHERE agent_id = $1",
          [open_agent]
        )
      end,
      code: :integrity_constraint_violation,
      message: ~r/immutable/i
    )

    Arbor.Persistence.Repo.query!(
      """
      UPDATE vector_agent_fences
      SET state = 'destroying', closed_at = NULL, updated_at = CURRENT_TIMESTAMP
      WHERE agent_id = $1
      """,
      [open_agent]
    )

    assert %{num_rows: 1} =
             Arbor.Persistence.Repo.query!(
               "DELETE FROM vector_operation_receipts WHERE agent_id = $1",
               [open_agent]
             )
  end

  test "fence table exists with coherent closed_at and agent_id byte constraints" do
    assert %{rows: [[true]]} =
             Arbor.Persistence.Repo.query!("""
             SELECT EXISTS (
               SELECT 1 FROM information_schema.tables
               WHERE table_schema = current_schema()
                 AND table_name = 'vector_agent_fences'
             )
             """)

    assert_postgres_error!(
      fn ->
        Arbor.Persistence.Repo.query!("""
        INSERT INTO vector_agent_fences (agent_id, state, closed_at, updated_at)
        VALUES ('bad_closed', 'closed', NULL, CURRENT_TIMESTAMP)
        """)
      end,
      code: :check_violation,
      message: ~r/vector_agent_fences_closed_at_coherent|closed_at/i
    )

    assert_postgres_error!(
      fn ->
        Arbor.Persistence.Repo.query!("""
        INSERT INTO vector_agent_fences (agent_id, state, closed_at, updated_at)
        VALUES ('bad_open', 'open', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        """)
      end,
      code: :check_violation,
      message: ~r/vector_agent_fences_closed_at_coherent|closed_at/i
    )

    assert_postgres_error!(
      fn ->
        Arbor.Persistence.Repo.query!("""
        INSERT INTO vector_agent_fences (agent_id, state, closed_at, updated_at)
        VALUES ('', 'open', NULL, CURRENT_TIMESTAMP)
        """)
      end,
      code: :check_violation,
      message: ~r/vector_agent_fences_agent_id_bytes_check|agent_id/i
    )

    assert_postgres_error!(
      fn ->
        Arbor.Persistence.Repo.query!("""
        INSERT INTO vector_agent_fences (agent_id, state, closed_at, updated_at)
        VALUES ('   ', 'open', NULL, CURRENT_TIMESTAMP)
        """)
      end,
      code: :check_violation,
      message: ~r/vector_agent_fences_agent_id_bytes_check|agent_id/i
    )

    oversize = String.duplicate("a", 257)

    # varchar(256) rejects 257 ASCII characters before CHECK runs.
    assert_postgres_error!(
      fn ->
        Arbor.Persistence.Repo.query!(
          """
          INSERT INTO vector_agent_fences (agent_id, state, closed_at, updated_at)
          VALUES ($1, 'open', NULL, CURRENT_TIMESTAMP)
          """,
          [oversize]
        )
      end,
      code: :string_data_right_truncation,
      message: ~r/value too long/i
    )

    # Multibyte byte-boundary: 128 two-byte codepoints (256 UTF-8 bytes) accepted;
    # 129 (258 bytes) rejected by the octet_length CHECK (129 chars fit varchar(256)).
    two_byte = "é"
    assert byte_size(two_byte) == 2
    accepted = String.duplicate(two_byte, 128)
    rejected = String.duplicate(two_byte, 129)
    assert byte_size(accepted) == 256
    assert byte_size(rejected) == 258

    assert %{num_rows: 1} =
             Arbor.Persistence.Repo.query!(
               """
               INSERT INTO vector_agent_fences (agent_id, state, closed_at, updated_at)
               VALUES ($1, 'open', NULL, CURRENT_TIMESTAMP)
               ON CONFLICT (agent_id) DO NOTHING
               """,
               [accepted]
             )

    assert_postgres_error!(
      fn ->
        Arbor.Persistence.Repo.query!(
          """
          INSERT INTO vector_agent_fences (agent_id, state, closed_at, updated_at)
          VALUES ($1, 'open', NULL, CURRENT_TIMESTAMP)
          """,
          [rejected]
        )
      end,
      code: :check_violation,
      message: ~r/vector_agent_fences_agent_id_bytes_check|agent_id/i
    )

    max_id = unique("max") <> String.duplicate("b", 200)
    max_id = binary_part(max_id <> String.duplicate("c", 256), 0, 256)

    assert %{num_rows: 1} =
             Arbor.Persistence.Repo.query!(
               """
               INSERT INTO vector_agent_fences (agent_id, state, closed_at, updated_at)
               VALUES ($1, 'open', NULL, CURRENT_TIMESTAMP)
               ON CONFLICT (agent_id) DO NOTHING
               """,
               [max_id]
             )

    # Outer sandbox remains healthy after isolated failures.
    assert %{rows: [[1]]} = Arbor.Persistence.Repo.query!("SELECT 1")
  end

  test "ordinary ops fail closed while fence is destroying; destroy retry closes", %{
    agent_id: agent_id
  } do
    operation = insert_operation!(record!(agent_id, source_key: "pg-destroying"))
    assert {:ok, _} = Arbor.Persistence.execute_vector_operation(agent_id, operation)

    Arbor.Persistence.Repo.query!(
      """
      UPDATE vector_agent_fences
      SET state = 'destroying', closed_at = NULL, updated_at = CURRENT_TIMESTAMP
      WHERE agent_id = $1
      """,
      [agent_id]
    )

    assert {:error, :closed} =
             Arbor.Persistence.execute_vector_operation(
               agent_id,
               insert_operation!(record!(agent_id, source_key: "while-destroying"))
             )

    assert {:error, :closed} =
             Arbor.Persistence.fetch_vector_record(agent_id, "voice", "pg-destroying")

    assert {:error, :closed} = Arbor.Persistence.list_vector_records(agent_id)

    assert {:error, :closed} =
             Arbor.Persistence.reconcile_vector_operation(agent_id, operation)

    assert {:error, :closed} =
             Arbor.Persistence.search_vector_records(
               agent_id,
               unit_vector(0),
               search_opts(limit: 1)
             )

    assert :ok = Arbor.Persistence.destroy_vector_agent(agent_id)

    assert %{rows: [[0]]} =
             Arbor.Persistence.Repo.query!(
               """
               SELECT COUNT(*) FROM memory_embeddings
               WHERE agent_id = $1 AND vector_protocol = 'arbor_vector_store_v1'
               """,
               [agent_id]
             )

    assert %{rows: [[0]]} =
             Arbor.Persistence.Repo.query!(
               "SELECT COUNT(*) FROM vector_operation_receipts WHERE agent_id = $1",
               [agent_id]
             )

    assert %{rows: [["closed", closed_at]]} =
             Arbor.Persistence.Repo.query!(
               "SELECT state, closed_at FROM vector_agent_fences WHERE agent_id = $1",
               [agent_id]
             )

    assert not is_nil(closed_at)
  end

  test "fence migration backfills via Ecto.Migrator.up against pre-fence schema" do
    with_fence_migration_schema!(fn repo, _schema ->
      now = DateTime.utc_now()
      strict_agent = unique("strict")
      receipt_agent = unique("receipt")
      legacy_agent = unique("legacy")

      repo.query!(
        """
        INSERT INTO memory_embeddings (
          id, agent_id, content, content_hash, embedding,
          vector_protocol, source_namespace, source_key,
          generation, revision, tombstone, inserted_at, updated_at
        ) VALUES (
          $1, $2, '{}', $3, NULL,
          'arbor_vector_store_v1', 'voice', 'strict-key',
          1, 1, false, $4, $4
        )
        """,
        [
          unique("vec"),
          strict_agent,
          :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower),
          now
        ]
      )

      repo.query!(
        """
        INSERT INTO memory_embeddings (
          id, agent_id, content, content_hash, embedding,
          vector_protocol, source_namespace, source_key,
          generation, revision, tombstone, inserted_at, updated_at
        ) VALUES (
          $1, $2, '{}', $3, NULL,
          NULL, NULL, NULL,
          NULL, NULL, NULL, $4, $4
        )
        """,
        [
          unique("legacy"),
          legacy_agent,
          :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower),
          now
        ]
      )

      repo.query!(
        """
        INSERT INTO vector_operation_receipts (
          operation_fingerprint, agent_id, operation_kind,
          operation_json, operation_digest, receipt_json, receipt_digest, inserted_at
        ) VALUES ($1, $2, 'insert', '{}', $3, '{}', $4, $5)
        """,
        [
          :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower),
          receipt_agent,
          String.duplicate("d", 64),
          String.duplicate("e", 64),
          now
        ]
      )

      assert :ok ==
               Ecto.Migrator.up(
                 repo,
                 @fence_migration_version,
                 Arbor.Persistence.Repo.Migrations.CreateVectorAgentFences,
                 log: false
               )

      assert %{rows: [[1]]} =
               repo.query!(
                 """
                 SELECT COUNT(*) FROM vector_agent_fences
                 WHERE agent_id = $1 AND state = 'open'
                 """,
                 [strict_agent]
               )

      assert %{rows: [[1]]} =
               repo.query!(
                 """
                 SELECT COUNT(*) FROM vector_agent_fences
                 WHERE agent_id = $1 AND state = 'open'
                 """,
                 [receipt_agent]
               )

      assert %{rows: [[0]]} =
               repo.query!(
                 "SELECT COUNT(*) FROM vector_agent_fences WHERE agent_id = $1",
                 [legacy_agent]
               )
    end)
  end

  test "security regression: receipt guards bind fence authority to trigger schema" do
    with_fence_migration_schema!(fn repo, schema ->
      now = DateTime.utc_now()
      insert_agent = unique("closed")
      delete_agent = unique("open")
      seeded_fingerprint = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

      # Seed the delete receipt before trigger installation so neither trigger
      # function has a cached relation plan on the exercising connection.
      repo.query!(
        """
        INSERT INTO vector_operation_receipts (
          operation_fingerprint, agent_id, operation_kind,
          operation_json, operation_digest, receipt_json, receipt_digest, inserted_at
        ) VALUES ($1, $2, 'insert', '{}', $3, '{}', $4, $5)
        """,
        [
          seeded_fingerprint,
          delete_agent,
          String.duplicate("1", 64),
          String.duplicate("2", 64),
          now
        ]
      )

      assert :ok ==
               Ecto.Migrator.up(
                 repo,
                 @fence_migration_version,
                 Arbor.Persistence.Repo.Migrations.CreateVectorAgentFences,
                 log: false
               )

      real_schema = quote_identifier(schema)

      repo.query!(
        """
        INSERT INTO #{real_schema}.vector_agent_fences
          (agent_id, state, closed_at, updated_at)
        VALUES ($1, 'closed', clock_timestamp() AT TIME ZONE 'UTC',
                clock_timestamp() AT TIME ZONE 'UTC')
        """,
        [insert_agent]
      )

      # Opposite shadow states would authorize both mutations if a trigger
      # resolved its authority through caller search_path. Each expected SQL
      # error owns its transaction so the aborted transaction cannot mask the
      # second assertion.
      assert_postgres_error!(
        repo,
        fn ->
          repo.query!("""
          CREATE TEMP TABLE vector_agent_fences (
            agent_id varchar(256) PRIMARY KEY,
            state varchar(16) NOT NULL
          ) ON COMMIT DROP
          """)

          repo.query!(
            "INSERT INTO pg_temp.vector_agent_fences (agent_id, state) VALUES ($1, 'open')",
            [insert_agent]
          )

          repo.query!(
            """
            INSERT INTO #{real_schema}.vector_operation_receipts (
              operation_fingerprint, agent_id, operation_kind,
              operation_json, operation_digest, receipt_json,
              receipt_digest, inserted_at
            ) VALUES ($1, $2, 'insert', '{}', $3, '{}', $4, $5)
            """,
            [
              :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower),
              insert_agent,
              String.duplicate("3", 64),
              String.duplicate("4", 64),
              now
            ]
          )
        end,
        code: :integrity_constraint_violation,
        message: ~r/fence not open/i
      )

      assert_postgres_error!(
        repo,
        fn ->
          repo.query!("""
          CREATE TEMP TABLE vector_agent_fences (
            agent_id varchar(256) PRIMARY KEY,
            state varchar(16) NOT NULL
          ) ON COMMIT DROP
          """)

          repo.query!(
            """
            INSERT INTO pg_temp.vector_agent_fences (agent_id, state)
            VALUES ($1, 'destroying')
            """,
            [delete_agent]
          )

          repo.query!(
            "DELETE FROM #{real_schema}.vector_operation_receipts WHERE agent_id = $1",
            [delete_agent]
          )
        end,
        code: :integrity_constraint_violation,
        message: ~r/immutable/i
      )

      assert %{rows: [[1]]} =
               repo.query!(
                 "SELECT COUNT(*) FROM vector_operation_receipts WHERE agent_id = $1",
                 [delete_agent]
               )
    end)
  end

  test "security regression: fence migration fails closed on pre-existing table collision" do
    with_fence_migration_schema!(fn repo, _schema ->
      repo.query!("CREATE TABLE vector_agent_fences (agent_id varchar(256) PRIMARY KEY)")

      error =
        try do
          Ecto.Migrator.up(
            repo,
            @fence_migration_version,
            Arbor.Persistence.Repo.Migrations.CreateVectorAgentFences,
            log: false
          )

          flunk("expected table collision to fail closed")
        rescue
          e -> e
        end

      assert Exception.message(error) =~ ~r/already exists|duplicate/i

      # Wrong pre-existing definition is retained; migration did not silently adopt it.
      assert %{rows: [["agent_id"]]} =
               repo.query!("""
               SELECT column_name
               FROM information_schema.columns
               WHERE table_schema = current_schema()
                 AND table_name = 'vector_agent_fences'
               ORDER BY ordinal_position
               """)
    end)
  end

  test "security regression: fence migration fails closed on pre-existing function collision" do
    with_fence_migration_schema!(fn repo, _schema ->
      repo.query!("""
      CREATE FUNCTION arbor_vector_receipt_ledger_immutable_update()
      RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'function collision sentinel';
      END;
      $$ LANGUAGE plpgsql
      """)

      error =
        try do
          Ecto.Migrator.up(
            repo,
            @fence_migration_version,
            Arbor.Persistence.Repo.Migrations.CreateVectorAgentFences,
            log: false
          )

          flunk("expected function collision to fail closed")
        rescue
          e -> e
        end

      assert Exception.message(error) =~ ~r/already exists|duplicate/i

      assert %{rows: [[definition]]} =
               repo.query!("""
               SELECT pg_get_functiondef(proc.oid)
               FROM pg_proc AS proc
               JOIN pg_namespace AS namespace ON namespace.oid = proc.pronamespace
               WHERE namespace.nspname = current_schema()
                 AND proc.proname = 'arbor_vector_receipt_ledger_immutable_update'
               """)

      assert definition =~ "function collision sentinel"
    end)
  end

  test "security regression: fence migration fails closed on pre-existing trigger collision" do
    with_fence_migration_schema!(fn repo, _schema ->
      repo.query!("""
      CREATE OR REPLACE FUNCTION arbor_vector_fence_collision_dummy()
      RETURNS trigger AS $$
      BEGIN
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      """)

      repo.query!("""
      CREATE TRIGGER vector_operation_receipts_admit_insert
      BEFORE INSERT ON vector_operation_receipts
      FOR EACH ROW EXECUTE FUNCTION arbor_vector_fence_collision_dummy()
      """)

      error =
        try do
          Ecto.Migrator.up(
            repo,
            @fence_migration_version,
            Arbor.Persistence.Repo.Migrations.CreateVectorAgentFences,
            log: false
          )

          flunk("expected trigger collision to fail closed")
        rescue
          e -> e
        end

      assert Exception.message(error) =~ ~r/already exists|duplicate/i

      assert %{rows: [[true]]} =
               repo.query!("""
               SELECT EXISTS (
                 SELECT 1 FROM pg_trigger
                 WHERE tgname = 'vector_operation_receipts_admit_insert'
               )
               """)
    end)
  end

  test "security regression: PostgreSQL-only legacy readers and single delete isolate V1 rows",
       %{agent_id: agent_id} do
    source_key = unique("legacy-isolation")
    record = record!(agent_id, source_key: source_key, vector: unit_vector(0))
    insert = insert_operation!(record)

    assert {:ok, inserted} = Arbor.Persistence.execute_vector_operation(agent_id, insert)

    assert {:ok, []} =
             Arbor.Persistence.search_legacy_embeddings(agent_id, inserted.record.vector,
               threshold: 0.0
             )

    assert %{total: 0, by_type: %{}} = Arbor.Persistence.legacy_embedding_stats(agent_id)

    delete = operation!(:delete, inserted.record)
    assert {:ok, deleted} = Arbor.Persistence.execute_vector_operation(agent_id, delete)

    assert {:ok, []} =
             Arbor.Persistence.search_legacy_embeddings(agent_id, inserted.record.vector,
               threshold: 0.0
             )

    assert %{total: 0, by_type: %{}} = Arbor.Persistence.legacy_embedding_stats(agent_id)

    assert {:error, :not_found} =
             Arbor.Persistence.fetch_legacy_embedding(agent_id, inserted.record.id)

    assert {:error, :protected_vector_row} =
             Arbor.Persistence.delete_legacy_embedding(agent_id, inserted.record.id)

    deleted_record = deleted.record

    assert {:ok, ^deleted_record} =
             Arbor.Persistence.fetch_vector_record(agent_id, "voice", source_key,
               include_tombstone: true
             )
  end

  defp record!(agent_id, overrides) do
    overrides = Map.new(overrides)
    payload = Map.get(overrides, :payload, %{"content" => unique("payload")})
    vector = Map.get(overrides, :vector, unit_vector(0))
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

  defp fetch!(agent_id, source_key) do
    {:ok, record} = Arbor.Persistence.fetch_vector_record(agent_id, "voice", source_key)
    record
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

  defp receive_ecto_search_sql(deadline: deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      flunk("timed out waiting for Ecto search SQL telemetry containing <=>")
    else
      receive do
        {:ecto_query, query} when is_binary(query) ->
          if String.contains?(query, "<=>") and String.contains?(query, "memory_embeddings") do
            query
          else
            receive_ecto_search_sql(deadline: deadline)
          end

        {:ecto_query, _other} ->
          receive_ecto_search_sql(deadline: deadline)
      after
        max(remaining, 1) ->
          flunk("timed out waiting for Ecto search SQL telemetry containing <=>")
      end
    end
  end

  defp search_opts(overrides) do
    Keyword.merge(
      [
        model_id: "provider/model-v1",
        dimensions: VectorRecord.dimensions(),
        encoding: VectorRecord.encoding(),
        category: "voice"
      ],
      overrides
    )
  end

  defp unit_vector(index) do
    List.replace_at(List.duplicate(0.0, VectorRecord.dimensions()), index, 1.0)
  end

  defp unique(prefix) do
    suffix = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    "#{prefix}_#{suffix}"
  end

  defp restore_env(key, :not_configured), do: Application.delete_env(:arbor_persistence, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_persistence, key, value)

  # The transaction boundary rolls back intentional DB errors before the next
  # query. Do not call this helper from inside another explicit Repo transaction.
  defp assert_postgres_error!(fun, opts),
    do: assert_postgres_error!(Arbor.Persistence.Repo, fun, opts)

  defp assert_postgres_error!(repo, fun, opts) do
    expected_codes =
      case Keyword.fetch!(opts, :code) do
        code when is_atom(code) -> [code]
        codes when is_list(codes) -> codes
      end

    message_re = Keyword.fetch!(opts, :message)

    error =
      assert_raise Postgrex.Error, fn ->
        repo.transaction(fn ->
          fun.()
          flunk("expected Postgrex.Error inside savepoint")
        end)
      end

    assert %Postgrex.Error{postgres: postgres} = error

    assert postgres.code in expected_codes,
           "expected code in #{inspect(expected_codes)}, got #{inspect(postgres.code)}: #{postgres.message}"

    assert postgres.code != :in_failed_sql_transaction
    assert postgres.message =~ message_re
    error
  end

  defp with_fence_migration_schema!(fun) do
    schema = "vector_fence_mig_#{System.unique_integer([:positive])}"
    admin_opts = fence_postgres_opts()
    {:ok, admin} = Postgrex.start_link(admin_opts)
    Postgrex.query!(admin, "CREATE SCHEMA #{quote_identifier(schema)}")

    # Stop any prior instance so the module name is free (async: false).
    if Process.whereis(FenceMigrationRepo), do: GenServer.stop(FenceMigrationRepo)

    {:ok, repo_pid} =
      FenceMigrationRepo.start_link(
        Keyword.merge(admin_opts,
          pool_size: 2,
          after_connect: fn conn ->
            Postgrex.query!(conn, "SET search_path TO #{quote_identifier(schema)}", [])
          end
        )
      )

    Process.unlink(repo_pid)

    try do
      create_pre_fence_tables!(FenceMigrationRepo)
      fun.(FenceMigrationRepo, schema)
    after
      if Process.alive?(repo_pid), do: GenServer.stop(repo_pid)
      Postgrex.query!(admin, "DROP SCHEMA IF EXISTS #{quote_identifier(schema)} CASCADE")
      GenServer.stop(admin)
    end
  end

  defp create_pre_fence_tables!(repo) do
    repo.query!("""
    CREATE TABLE memory_embeddings (
      id varchar(255) PRIMARY KEY,
      agent_id varchar(256),
      content text NOT NULL DEFAULT '{}',
      content_hash varchar(64) NOT NULL,
      embedding text,
      vector_protocol varchar(64),
      source_namespace varchar(128),
      source_key varchar(1024),
      generation bigint,
      revision bigint,
      tombstone boolean,
      inserted_at timestamp(6) without time zone NOT NULL,
      updated_at timestamp(6) without time zone NOT NULL
    )
    """)

    repo.query!("""
    CREATE TABLE vector_operation_receipts (
      operation_fingerprint varchar(64) PRIMARY KEY,
      agent_id varchar(256) NOT NULL,
      operation_kind varchar(16) NOT NULL,
      operation_json text NOT NULL,
      operation_digest varchar(64) NOT NULL,
      receipt_json text NOT NULL,
      receipt_digest varchar(64) NOT NULL,
      inserted_at timestamp(6) without time zone NOT NULL
    )
    """)
  end

  defp fence_postgres_opts do
    config = Arbor.Persistence.Repo.config()

    [
      username: Keyword.get(config, :username, System.get_env("POSTGRES_USER", "arbor_dev")),
      password: Keyword.get(config, :password, System.get_env("POSTGRES_PASSWORD", "")),
      database: Keyword.get(config, :database, System.get_env("POSTGRES_DB", "trust_arbor_test")),
      hostname: Keyword.get(config, :hostname, System.get_env("POSTGRES_HOST", "localhost")),
      port:
        Keyword.get(
          config,
          :port,
          String.to_integer(System.get_env("POSTGRES_PORT", "5432"))
        ),
      prepare: :unnamed
    ]
  end

  defp quote_identifier(identifier),
    do: ~s("#{String.replace(identifier, "\"", "\"\"")}")
end
