defmodule Arbor.Persistence.VectorStore.EctoPostgresTest do
  use Arbor.Persistence.DatabaseCase, async: false

  alias Arbor.Contracts.Persistence.{VectorMatch, VectorOperation, VectorRecord}

  @moduletag :database
  @moduletag :integration
  @moduletag :postgres

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
end
