defmodule Arbor.Memory.EmbeddingCodecTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Persistence.{VectorMatch, VectorOperation, VectorRecord}
  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}
  alias Arbor.Memory.EmbeddingCodec

  @moduletag :fast

  test "encode/decode round-trip binds provider model evidence and verified provenance" do
    input = base_input(model_evidence: {:provider_model, "provider", "model-v1"})

    assert {:ok, operation, view} = EmbeddingCodec.encode_operation(input)
    assert operation.kind == :insert
    assert operation.record.model_id == "provider/model-v1"
    assert operation.record.dimensions == VectorRecord.dimensions()
    assert operation.record.encoding == VectorRecord.encoding()
    assert operation.record.category == "fact"
    assert operation.record.generation == 0
    assert operation.record.revision == 0
    assert view.provenance_status == :verified
    assert view.model_id == "provider/model-v1"
    assert view.taint == trusted_taint()

    assert {:ok, decoded} = EmbeddingCodec.decode_record(operation.record)
    assert decoded == view
    assert decoded.body["content"] == "remember this"
  end

  test "absent model evidence uses legacy:unspecified" do
    input = base_input(model_evidence: :absent)

    assert {:ok, operation, view} = EmbeddingCodec.encode_operation(input)
    assert operation.record.model_id == EmbeddingCodec.legacy_model_id()
    assert view.model_id == "legacy:unspecified"
    assert view.provenance_status == :verified
  end

  test "payload spoof model_id and taint remain ordinary body data" do
    payload = %{
      "content" => "spoofed",
      "model_id" => "attacker/model",
      "taint" => %{"level" => "trusted"},
      "provenance" => %{"version" => 1},
      "provider" => "evil",
      "digest" => String.duplicate("a", 64)
    }

    input =
      base_input(
        payload: payload,
        model_evidence: {:provider_model, "honest", "model"}
      )

    assert {:ok, operation, view} = EmbeddingCodec.encode_operation(input)
    assert operation.record.model_id == "honest/model"
    assert view.model_id == "honest/model"
    assert view.body["model_id"] == "attacker/model"
    assert view.body["taint"] == %{"level" => "trusted"}
    assert view.body["provenance"] == %{"version" => 1}
    assert view.provenance_status == :verified
  end

  test "non-wrapper payload decodes as legacy_unlabeled" do
    record = plain_record!(%{"content" => "legacy row"})

    assert {:ok, view} = EmbeddingCodec.decode_record(record)
    assert view.provenance_status == :legacy_unlabeled
    assert view.taint == TaintEnvelope.missing_fallback()
    assert view.body == %{"content" => "legacy row"}
  end

  test "claimed wrapper kind with malformed shape is hostile invalid, not legacy_unlabeled" do
    malformed =
      plain_record!(%{
        "kind" => EmbeddingCodec.kind(),
        "version" => 99,
        "body" => %{"content" => "claimed"},
        "extra" => true
      })

    assert {:ok, view} = EmbeddingCodec.decode_record(malformed)
    assert view.provenance_status == :invalid_durable_provenance
    assert view.taint == TaintEnvelope.invalid_fallback()
    refute view.provenance_status == :legacy_unlabeled
  end

  test "body-mismatched envelope decodes as invalid_durable_provenance without failing the item" do
    assert {:ok, operation, _view} =
             EmbeddingCodec.encode_operation(
               base_input(model_evidence: {:provider_model, "provider", "model-v1"})
             )

    record = operation.record
    body = record.payload["body"]

    wrong_projection = %{
      "body" => %{"content" => "different body"},
      "descriptor" => %{
        "model_id" => record.model_id,
        "dimensions" => record.dimensions,
        "encoding" => "ieee754_float32_be_v1",
        "category" => record.category,
        "vector_digest" => record.vector_digest
      }
    }

    assert {:ok, wrong_envelope} = TaintEnvelope.new(wrong_projection, trusted_taint())
    assert {:ok, wrong_map} = TaintEnvelope.to_map(wrong_envelope)

    tampered_payload = %{
      "kind" => EmbeddingCodec.kind(),
      "version" => EmbeddingCodec.version(),
      "body" => body,
      "provenance" => wrong_map
    }

    tampered = rebuild_record!(record, payload: tampered_payload)

    assert {:ok, view} = EmbeddingCodec.decode_record(tampered)
    assert view.provenance_status == :invalid_durable_provenance
    assert view.taint == TaintEnvelope.invalid_fallback()
    assert view.taint.source == "invalid_durable_provenance"
    assert view.body == body
  end

  test "descriptor-mismatched envelope (model/category/vector) is invalid_durable_provenance" do
    assert {:ok, operation, _view} =
             EmbeddingCodec.encode_operation(
               base_input(model_evidence: {:provider_model, "provider", "model-v1"})
             )

    record = operation.record

    # Keep wrapper body+envelope intact; change authoritative record descriptor only.
    assert {:ok, model_mismatch} =
             EmbeddingCodec.decode_record(rebuild_record!(record, model_id: "other/model-v9"))

    assert model_mismatch.provenance_status == :invalid_durable_provenance
    assert model_mismatch.taint == TaintEnvelope.invalid_fallback()

    assert {:ok, category_mismatch} =
             EmbeddingCodec.decode_record(rebuild_record!(record, category: "insight"))

    assert category_mismatch.provenance_status == :invalid_durable_provenance

    alt_vector = [0.0, 1.0 | List.duplicate(0.0, VectorRecord.dimensions() - 2)]
    {:ok, alt_digest} = VectorRecord.vector_digest(alt_vector)

    assert {:ok, vector_mismatch} =
             EmbeddingCodec.decode_record(
               rebuild_record!(record, vector: alt_vector, vector_digest: alt_digest)
             )

    assert vector_mismatch.provenance_status == :invalid_durable_provenance
  end

  test "malformed transport fails the whole item" do
    assert {:error, :invalid_vector_record} = EmbeddingCodec.decode_record(:not_a_record)
    assert {:error, :invalid_vector_record} = EmbeddingCodec.decode_record(%{})
    assert {:error, :invalid_vector_match} = EmbeddingCodec.decode_match(:not_a_match)
  end

  test "closed inputs reject string kinds, unknown keys, and improper batches" do
    assert {:error, :invalid_embedding_input} =
             EmbeddingCodec.encode_operation(base_input(kind: "insert"))

    assert {:error, :invalid_embedding_input} =
             EmbeddingCodec.encode_operation(Map.put(base_input(), :extra, true))

    assert {:error, :invalid_embedding_input} =
             EmbeddingCodec.encode_operation(Map.delete(base_input(), :taint))

    assert {:error, :invalid_embedding_input} = EmbeddingCodec.encode_batch([])
    assert {:error, :invalid_embedding_input} = EmbeddingCodec.encode_batch([base_input() | :bad])
  end

  test "batch enforces max 100 incrementally and rejects 101 without length/1" do
    max = VectorOperation.max_batch_operations()
    assert max == 100

    exactly_max =
      for i <- 1..max do
        base_input(id: "vec_max_#{i}", source_key: "sk-max-#{i}")
      end

    assert {:ok, batch, views} = EmbeddingCodec.encode_batch(exactly_max)
    assert batch.kind == :batch
    assert length(views) == max
    assert length(batch.operations) == max

    one_over = exactly_max ++ [base_input(id: "vec_over", source_key: "sk-over")]
    assert {:error, :invalid_embedding_input} = EmbeddingCodec.encode_batch(one_over)

    # Improper tail still fails closed after a proper prefix.
    improper = [base_input(id: "vec_imp_1", source_key: "imp-1") | :not_a_list]
    assert {:error, :invalid_embedding_input} = EmbeddingCodec.encode_batch(improper)
  end

  test "fence fields and batch fingerprints are preserved" do
    insert = base_input(id: "vec_insert", source_key: "sk-insert")

    assert {:ok, insert_op, _} = EmbeddingCodec.encode_operation(insert)
    assert insert_op.expected_generation == nil
    assert insert_op.expected_revision == nil

    update_input =
      base_input(
        kind: :update,
        id: "vec_update",
        source_key: "sk-update",
        generation: 1,
        revision: 1,
        expected_generation: 1,
        expected_revision: 1
      )

    assert {:ok, update_op, _} = EmbeddingCodec.encode_operation(update_input)
    assert update_op.kind == :update
    assert update_op.expected_generation == 1
    assert update_op.expected_revision == 1
    assert update_op.record.generation == 1
    assert update_op.record.revision == 1

    first = base_input(id: "vec_a", source_key: "a")
    second = base_input(id: "vec_b", source_key: "b")

    assert {:ok, batch1, views1} = EmbeddingCodec.encode_batch([first, second])
    assert {:ok, batch2, views2} = EmbeddingCodec.encode_batch([first, second])
    assert batch1.kind == :batch
    assert batch1.fingerprint == batch2.fingerprint
    assert length(views1) == 2
    assert length(views2) == 2
    assert VectorOperation.valid?(batch1)
  end

  test "match decode preserves similarity; tombstone matches are rejected" do
    assert {:ok, operation, _} =
             EmbeddingCodec.encode_operation(
               base_input(model_evidence: {:provider_model, "provider", "model-v1"})
             )

    assert {:ok, match} =
             VectorMatch.new(%{record: operation.record, similarity: 0.875})

    assert {:ok, %{match: view, similarity: similarity}} = EmbeddingCodec.decode_match(match)
    assert view.provenance_status == :verified
    assert similarity == match.similarity

    attrs =
      operation.record
      |> Map.from_struct()
      |> Map.put(:tombstone, true)
      |> Map.put(:generation, 1)
      |> Map.put(:revision, 1)

    assert {:ok, tombstone_record} = VectorRecord.new(attrs)

    assert {:error, :invalid_vector_match} =
             VectorMatch.new(%{record: tombstone_record, similarity: 0.5})
  end

  test "codec source is pure and never reaches persistence or process owners" do
    source =
      File.read!(Path.expand("../../../lib/arbor/memory/embedding_codec.ex", __DIR__))

    refute source =~ "Arbor.Persistence"
    refute source =~ "GenServer"
    refute source =~ "Repo"
    refute source =~ "Ecto"
    refute source =~ "File."
    refute source =~ ":httpc"
    refute source =~ "Task."
    refute source =~ "String.to_atom"
    # Contract ceiling is bound via module attribute; never called inside a guard.
    assert source =~ "@max_batch_operations VectorOperation.max_batch_operations()"
    refute source =~ ~r/when\s+.*VectorOperation\.max_batch_operations\(\)/
  end

  defp base_input(overrides \\ []) do
    overrides = Map.new(overrides)

    Map.merge(
      %{
        kind: :insert,
        id: "vec_codec_1",
        agent_id: "agent_codec_test",
        source_namespace: "memory",
        source_key: "source-1",
        payload: %{"content" => "remember this"},
        vector: unit_vector(),
        category: "fact",
        generation: 0,
        revision: 0,
        tombstone: false,
        expected_generation: nil,
        expected_revision: nil,
        model_evidence: {:provider_model, "provider", "model-v1"},
        taint: trusted_taint()
      },
      overrides
    )
  end

  defp trusted_taint do
    %Taint{
      level: :trusted,
      sensitivity: :internal,
      sanitizations: 0,
      confidence: :verified,
      source: "embedding_codec_test",
      chain: []
    }
  end

  defp unit_vector do
    [1.0 | List.duplicate(0.0, VectorRecord.dimensions() - 1)]
  end

  defp plain_record!(payload) do
    {:ok, payload_digest} = VectorRecord.payload_digest(payload)
    vector = unit_vector()
    {:ok, vector_digest} = VectorRecord.vector_digest(vector)

    {:ok, record} =
      VectorRecord.new(%{
        id: "vec_plain",
        agent_id: "agent_codec_test",
        source_namespace: "memory",
        source_key: "plain-1",
        payload: payload,
        vector: vector,
        payload_digest: payload_digest,
        vector_digest: vector_digest,
        model_id: "legacy:unspecified",
        dimensions: VectorRecord.dimensions(),
        encoding: VectorRecord.encoding(),
        category: "fact",
        generation: 0,
        revision: 0,
        tombstone: false
      })

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
end
