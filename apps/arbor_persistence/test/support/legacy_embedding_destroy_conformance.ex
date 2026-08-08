defmodule Arbor.Persistence.LegacyEmbeddingDestroyConformance do
  @moduledoc false

  # Shared SQLite/PostgreSQL evidence for VP-05D2C3I0C3 destroy_legacy_embeddings.

  import ExUnit.Assertions

  alias Arbor.Contracts.Persistence.{VectorOperation, VectorRecord}
  alias Arbor.Persistence.VectorStore.Ecto.VectorRow

  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)

    quote do
      test "VP-05D2C3I0C3: destroy_legacy_embeddings removes target legacy only",
           %{agent_id: agent_id} do
        Arbor.Persistence.LegacyEmbeddingDestroyConformance.assert_destroy_isolation(
          unquote(repo),
          agent_id
        )
      end
    end
  end

  def assert_destroy_isolation(repo, target_agent) do
    survivor_agent = unique("survivor")
    vector = vector(0)

    # Target legacy rows
    legacy_id_1 =
      insert_legacy!(repo, target_agent, unique("target-legacy-1"), vector, %{
        "type" => "note"
      })

    _legacy_id_2 =
      insert_legacy!(repo, target_agent, unique("target-legacy-2"), vector, %{
        "type" => "note"
      })

    # Survivor legacy
    survivor_legacy_id =
      insert_legacy!(repo, survivor_agent, unique("survivor-legacy"), vector, %{
        "type" => "note"
      })

    assert %VectorRow{memory_type: "note", metadata: %{"type" => "note"}} =
             repo.get!(VectorRow, legacy_id_1)

    # Target strict V1
    target_strict =
      insert_operation!(
        record!(target_agent, unique("strict-target"), %{"content" => "target-strict"})
      )

    assert {:ok, target_receipt} =
             Arbor.Persistence.execute_vector_operation(target_agent, target_strict)

    # Survivor strict V1
    survivor_strict =
      insert_operation!(
        record!(survivor_agent, unique("strict-survivor"), %{"content" => "survivor-strict"})
      )

    assert {:ok, survivor_receipt} =
             Arbor.Persistence.execute_vector_operation(survivor_agent, survivor_strict)

    assert {:ok, false} =
             Arbor.Persistence.legacy_embeddings_absent?(target_agent, repo: repo)

    assert :ok = Arbor.Persistence.destroy_legacy_embeddings(target_agent, repo: repo)

    assert {:ok, true} =
             Arbor.Persistence.legacy_embeddings_absent?(target_agent, repo: repo)

    assert 0 == Arbor.Persistence.count_legacy_embeddings(target_agent, repo: repo)

    assert is_nil(repo.get(VectorRow, legacy_id_1))

    # Idempotent retry
    assert :ok = Arbor.Persistence.destroy_legacy_embeddings(target_agent, repo: repo)
    assert {:ok, true} = Arbor.Persistence.legacy_embeddings_absent?(target_agent, repo: repo)

    # Target strict retained
    target_record = target_receipt.record

    assert {:ok, ^target_record} =
             Arbor.Persistence.fetch_vector_record(
               target_agent,
               target_record.source_namespace,
               target_record.source_key
             )

    # Survivor legacy retained
    survivor_row = repo.get!(VectorRow, survivor_legacy_id)

    assert survivor_row.id == survivor_legacy_id
    assert survivor_row.agent_id == survivor_agent

    assert {:ok, false} =
             Arbor.Persistence.legacy_embeddings_absent?(survivor_agent, repo: repo)

    # Survivor strict retained
    survivor_record = survivor_receipt.record

    assert {:ok, ^survivor_record} =
             Arbor.Persistence.fetch_vector_record(
               survivor_agent,
               survivor_record.source_namespace,
               survivor_record.source_key
             )
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

  defp insert_operation!(record) do
    {:ok, operation} =
      VectorOperation.new(%{
        kind: :insert,
        record: record,
        expected_generation: nil,
        expected_revision: nil
      })

    operation
  end

  defp insert_legacy!(repo, agent_id, content, vector, metadata) do
    id = unique("legacy")
    now = DateTime.utc_now()

    row = %VectorRow{
      id: id,
      agent_id: agent_id,
      content: content,
      content_hash: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower),
      embedding: encode_vector(repo, vector),
      memory_type: Map.get(metadata, "type"),
      source: Map.get(metadata, "source"),
      metadata: metadata,
      inserted_at: now,
      updated_at: now
    }

    assert {:ok, %VectorRow{id: ^id}} = repo.insert(row)
    id
  end

  defp encode_vector(repo, vector) do
    case repo.__adapter__() do
      Ecto.Adapters.SQLite3 -> Jason.encode!(vector)
      Ecto.Adapters.Postgres -> Pgvector.new(vector)
      adapter -> flunk("unsupported test repo adapter: #{inspect(adapter)}")
    end
  end

  defp vector(index) do
    List.replace_at(List.duplicate(0.0, VectorRecord.dimensions()), index, 1.0)
  end

  defp unique(prefix) do
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    "#{prefix}_#{suffix}"
  end
end
