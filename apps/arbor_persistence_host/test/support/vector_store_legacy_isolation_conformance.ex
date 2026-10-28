defmodule Arbor.Persistence.VectorStore.LegacyIsolationConformance do
  @moduledoc false

  import Ecto.Query
  import ExUnit.Assertions

  alias Arbor.Contracts.Persistence.{VectorOperation, VectorRecord}
  alias Arbor.Persistence.VectorStore.Ecto.VectorRow

  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    legacy_mutations? = Keyword.get(opts, :legacy_mutations, false)

    mutation_tests =
      if legacy_mutations? do
        quote do
          test "security regression: legacy upserts cannot mutate a V1-owned conflict",
               %{agent_id: agent_id} do
            Arbor.Persistence.VectorStore.LegacyIsolationConformance.assert_conflict_isolation(
              unquote(repo),
              agent_id
            )
          end

          test "security regression: a mixed legacy batch conflict rolls back unrelated writes",
               %{agent_id: agent_id} do
            Arbor.Persistence.VectorStore.LegacyIsolationConformance.assert_mixed_batch_rollback(
              unquote(repo),
              agent_id
            )
          end
        end
      else
        quote do
        end
      end

    quote do
      test "security regression: legacy APIs cannot observe, delete, or overwrite V1 rows",
           %{agent_id: agent_id} do
        Arbor.Persistence.VectorStore.LegacyIsolationConformance.assert_tombstone_isolation(
          unquote(repo),
          agent_id
        )
      end

      unquote(mutation_tests)
    end
  end

  def assert_tombstone_isolation(repo, agent_id) do
    source_key = unique("isolated")
    forged_agent = unique("forged_agent")

    payload = %{
      "content" => "V1 authority",
      "metadata" => %{
        "agent_id" => forged_agent,
        "source_namespace" => "legacy",
        "source_key" => "forged",
        "vector_protocol" => "legacy"
      },
      "caller_metadata" => %{"provenance" => "trusted"}
    }

    insert = insert_operation!(record!(agent_id, source_key, payload))
    assert {:ok, inserted} = Arbor.Persistence.execute_vector_operation(agent_id, insert)

    assert inserted.record.agent_id == agent_id
    assert inserted.record.source_namespace == "voice"

    assert {:error, :not_found} =
             Arbor.Persistence.fetch_vector_record(forged_agent, "legacy", "forged")

    assert {:error, :not_found} =
             Arbor.Persistence.fetch_legacy_embedding(agent_id, inserted.record.id, repo: repo)

    assert 0 == Arbor.Persistence.count_legacy_embeddings(agent_id, repo: repo)
    assert {:ok, 0} = Arbor.Persistence.delete_all_legacy_embeddings(agent_id, repo: repo)

    assert {:error, :protected_vector_row} =
             Arbor.Persistence.store_legacy_embedding(
               agent_id,
               "legacy overwrite",
               vector(20),
               %{id: inserted.record.id},
               repo: repo
             )

    delete = operation!(:delete, inserted.record)
    assert {:ok, deleted} = Arbor.Persistence.execute_vector_operation(agent_id, delete)

    assert {:error, :not_found} =
             Arbor.Persistence.fetch_legacy_embedding(agent_id, inserted.record.id, repo: repo)

    assert 0 == Arbor.Persistence.count_legacy_embeddings(agent_id, repo: repo)
    assert {:ok, 0} = Arbor.Persistence.delete_all_legacy_embeddings(agent_id, repo: repo)

    assert {:error, :protected_vector_row} =
             Arbor.Persistence.store_legacy_embedding(
               agent_id,
               "tombstone overwrite",
               vector(21),
               %{id: inserted.record.id},
               repo: repo
             )

    deleted_record = deleted.record

    assert {:ok, ^deleted_record} =
             Arbor.Persistence.fetch_vector_record(agent_id, "voice", source_key,
               include_tombstone: true
             )

    assert {:ok, ^inserted} = Arbor.Persistence.reconcile_vector_operation(agent_id, insert)
  end

  def assert_conflict_isolation(repo, agent_id) do
    insert = insert_operation!(record!(agent_id, unique("conflict"), %{"content" => "owned"}))
    assert {:ok, inserted} = Arbor.Persistence.execute_vector_operation(agent_id, insert)

    legacy_content = unique("forced_collision")

    with_legacy_content_hash(repo, inserted.record.id, legacy_content, fn ->
      assert {:error, :protected_vector_row} =
               Arbor.Persistence.store_legacy_embedding(
                 agent_id,
                 legacy_content,
                 vector(21),
                 %{type: "single-overwrite"},
                 repo: repo
               )

      assert {:error, :protected_vector_row} =
               Arbor.Persistence.store_legacy_embedding_batch_with_ids(
                 agent_id,
                 [{legacy_content, vector(22), %{type: "batch-overwrite"}}],
                 repo: repo
               )

      assert {nil, %{}} == legacy_metadata(repo, inserted.record.id)
    end)

    inserted_record = inserted.record

    assert {:ok, ^inserted_record} =
             Arbor.Persistence.fetch_vector_record(agent_id, "voice", inserted.record.source_key)
  end

  def assert_mixed_batch_rollback(repo, agent_id) do
    insert =
      insert_operation!(record!(agent_id, unique("atomic_conflict"), %{"content" => "owned"}))

    assert {:ok, inserted} = Arbor.Persistence.execute_vector_operation(agent_id, insert)

    protected_content = unique("protected_content")
    unrelated_content = unique("must_roll_back")
    unrelated_id = unique("unrelated")

    with_legacy_content_hash(repo, inserted.record.id, protected_content, fn ->
      assert {:error, :protected_vector_row} =
               Arbor.Persistence.store_legacy_embedding_batch_with_ids(
                 agent_id,
                 [
                   {unrelated_content, vector(31), %{id: unrelated_id, type: "unrelated"}},
                   {protected_content, vector(32), %{type: "protected"}}
                 ],
                 repo: repo
               )

      assert {:error, :not_found} =
               Arbor.Persistence.fetch_legacy_embedding(agent_id, unrelated_id, repo: repo)

      assert 0 == Arbor.Persistence.count_legacy_embeddings(agent_id, repo: repo)
      assert {nil, %{}} == legacy_metadata(repo, inserted.record.id)
    end)

    inserted_record = inserted.record

    assert {:ok, ^inserted_record} =
             Arbor.Persistence.fetch_vector_record(agent_id, "voice", inserted.record.source_key)
  end

  defp record!(agent_id, source_key, payload) do
    vector = vector(0)
    {:ok, payload_digest} = VectorRecord.payload_digest(payload)
    {:ok, vector_digest} = VectorRecord.vector_digest(vector)

    {:ok, record} =
      VectorRecord.new(%{
        id: unique("vec"),
        agent_id: agent_id,
        source_namespace: "voice",
        source_key: source_key,
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
      })

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

  defp with_legacy_content_hash(repo, id, legacy_content, assertion) do
    query = from(row in VectorRow, where: row.id == ^id)
    original_hash = repo.one!(from(row in query, select: row.content_hash))
    collision_hash = :crypto.hash(:sha256, legacy_content) |> Base.encode16(case: :lower)

    {1, _rows} = repo.update_all(query, set: [content_hash: collision_hash])

    try do
      assertion.()
    after
      {1, _rows} = repo.update_all(query, set: [content_hash: original_hash])
    end
  end

  defp legacy_metadata(repo, id) do
    repo.one!(
      from(row in VectorRow,
        where: row.id == ^id,
        select: {row.memory_type, row.metadata}
      )
    )
  end

  defp vector(index) do
    List.replace_at(List.duplicate(0.0, VectorRecord.dimensions()), index, 1.0)
  end

  defp unique(prefix) do
    suffix = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    "#{prefix}_#{suffix}"
  end
end
