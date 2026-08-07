defmodule Arbor.Memory.EmbeddingStrictBoundaryTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Persistence.{VectorOperation, VectorRecord}
  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}
  alias Arbor.Memory.Embedding

  @moduletag :fast

  test "legacy API exports remain present and facade stays behind Persistence" do
    source = File.read!(Path.expand("../../../lib/arbor/memory/embedding.ex", __DIR__))
    Code.ensure_loaded!(Embedding)

    assert source =~ "alias Arbor.Persistence"
    assert source =~ "alias Arbor.Memory.EmbeddingCodec"
    refute source =~ "Arbor.Persistence.Repo"
    refute source =~ "Arbor.Persistence.Schemas"
    refute source =~ "Ecto.Query"
    refute source =~ "Pgvector"

    assert function_exported?(Embedding, :validate, 4)
    assert function_exported?(Embedding, :store, 4)
    assert function_exported?(Embedding, :search, 3)
    assert function_exported?(Embedding, :delete, 2)
    assert function_exported?(Embedding, :count, 1)
    assert function_exported?(Embedding, :stats, 1)
    assert function_exported?(Embedding, :store_batch, 2)
    assert function_exported?(Embedding, :get, 2)
    assert function_exported?(Embedding, :delete_all, 1)

    assert function_exported?(Embedding, :encode_strict_operation, 1)
    assert function_exported?(Embedding, :encode_strict_batch, 1)
    assert function_exported?(Embedding, :decode_strict_record, 1)
    assert function_exported?(Embedding, :decode_strict_match, 1)
    assert function_exported?(Embedding, :execute_strict, 3)
    assert function_exported?(Embedding, :reconcile_strict, 3)
    assert function_exported?(Embedding, :fetch_strict, 4)
    assert function_exported?(Embedding, :list_strict, 2)
    assert function_exported?(Embedding, :search_strict, 3)
    assert function_exported?(Embedding, :destroy_strict, 2)
  end

  test "destroy_strict and StrictVectorSeam.Default forward to public Persistence facade" do
    source = File.read!(Path.expand("../../../lib/arbor/memory/embedding.ex", __DIR__))

    default =
      File.read!(Path.expand("../../../lib/arbor/memory/strict_vector_seam/default.ex", __DIR__))

    seam = File.read!(Path.expand("../../../lib/arbor/memory/strict_vector_seam.ex", __DIR__))

    assert seam =~ "destroy(agent_id(), opts())"
    assert default =~ "def destroy(agent_id, opts \\\\ [])"
    assert default =~ "Embedding.destroy_strict"
    assert source =~ "Persistence.destroy_vector_agent"
    refute source =~ "Arbor.Persistence.VectorStore"
    refute source =~ "Arbor.Persistence.Repo"

    assert {:error, :unsupported} =
             Embedding.destroy_strict("agent_destroy_forward", [])

    assert {:error, :unsupported} =
             Arbor.Memory.StrictVectorSeam.Default.destroy("agent_destroy_forward", [])
  end

  test "strict public encode/decode round-trips through Arbor.Memory.Embedding" do
    input = base_input()

    assert {:ok, operation, view} = Embedding.encode_strict_operation(input)
    assert {:ok, ^view} = Embedding.decode_strict_record(operation.record)
    assert view.provenance_status == :verified
    assert view.model_id == "provider/model-v1"
  end

  test "execute_strict encodes locally then hits public Persistence boundary" do
    input = base_input(agent_id: "agent_strict_exec")

    # Default vector backend is Unsupported in unit env; encode still succeeds first.
    assert {:error, :unsupported} = Embedding.execute_strict(input.agent_id, input, [])
  end

  test "security regression: claimed malformed wrapper is hostile not legacy_unlabeled" do
    malformed =
      plain_record!(%{
        "kind" => "arbor_memory_embedding",
        "version" => 1,
        "body" => "not-a-map",
        "provenance" => "not-an-envelope"
      })

    assert {:ok, view} = Embedding.decode_strict_record(malformed)
    assert view.provenance_status == :invalid_durable_provenance
    assert view.taint == TaintEnvelope.invalid_fallback()
    refute view.provenance_status == :legacy_unlabeled

    truly_legacy = plain_record!(%{"content" => "no kind claim"})
    assert {:ok, legacy} = Embedding.decode_strict_record(truly_legacy)
    assert legacy.provenance_status == :legacy_unlabeled
  end

  test "security regression: execute/reconcile reject unlabeled and invalid-provenance VectorOperations" do
    agent_id = "agent_strict_admit"
    input = base_input(agent_id: agent_id)

    assert {:ok, verified_op, _} = Embedding.encode_strict_operation(input)
    # Verified raw operation is admitted; backend remains Unsupported.
    assert {:error, :unsupported} = Embedding.execute_strict(agent_id, verified_op, [])
    assert {:error, :unsupported} = Embedding.reconcile_strict(agent_id, verified_op, [])

    legacy_record = plain_record!(%{"content" => "unlabeled write attempt"})

    assert {:ok, unlabeled_op} =
             VectorOperation.new(%{
               kind: :insert,
               record: legacy_record,
               expected_generation: nil,
               expected_revision: nil
             })

    assert {:error, :unverified_strict_provenance} =
             Embedding.execute_strict(agent_id, unlabeled_op, [])

    assert {:error, :unverified_strict_provenance} =
             Embedding.reconcile_strict(agent_id, unlabeled_op, [])

    assert {:ok, good_op, _} = Embedding.encode_strict_operation(input)
    hostile_record = descriptor_mismatched_record!(good_op.record)

    assert {:ok, hostile_op} =
             VectorOperation.new(%{
               kind: :insert,
               record: hostile_record,
               expected_generation: nil,
               expected_revision: nil
             })

    assert {:error, :unverified_strict_provenance} =
             Embedding.execute_strict(agent_id, hostile_op, [])

    assert {:error, :unverified_strict_provenance} =
             Embedding.reconcile_strict(agent_id, hostile_op, [])
  end

  test "verified raw batch is admitted and preserves the exact VectorOperation" do
    agent_id = "agent_strict_batch_verified"

    first =
      base_input(
        agent_id: agent_id,
        id: "vec_batch_v1",
        source_key: "batch-v1"
      )

    second =
      base_input(
        agent_id: agent_id,
        id: "vec_batch_v2",
        source_key: "batch-v2"
      )

    assert {:ok, batch, views} = Embedding.encode_strict_batch([first, second])
    assert batch.kind == :batch
    assert length(views) == 2
    assert Enum.all?(views, &(&1.provenance_status == :verified))

    # Exact raw batch is admitted; unit backend remains Unsupported.
    assert {:error, :unsupported} = Embedding.execute_strict(agent_id, batch, [])
    assert {:error, :unsupported} = Embedding.reconcile_strict(agent_id, batch, [])
  end

  test "security regression: mixed-provenance raw batch is rejected before Persistence dispatch" do
    agent_id = "agent_strict_batch_mixed"

    assert {:ok, verified_op, _} =
             Embedding.encode_strict_operation(
               base_input(
                 agent_id: agent_id,
                 id: "vec_mixed_verified",
                 source_key: "mixed-verified"
               )
             )

    legacy_record =
      plain_record!(
        %{"content" => "unlabeled batch member"},
        agent_id: agent_id,
        id: "vec_mixed_legacy",
        source_key: "mixed-legacy"
      )

    assert {:ok, unlabeled_op} =
             VectorOperation.new(%{
               kind: :insert,
               record: legacy_record,
               expected_generation: nil,
               expected_revision: nil
             })

    assert {:ok, mixed_batch} =
             VectorOperation.new(%{
               kind: :batch,
               operations: [verified_op, unlabeled_op]
             })

    assert {:error, :unverified_strict_provenance} =
             Embedding.execute_strict(agent_id, mixed_batch, [])

    assert {:error, :unverified_strict_provenance} =
             Embedding.reconcile_strict(agent_id, mixed_batch, [])
  end

  test "caller/record agent_id mismatch returns Persistence tenant_mismatch" do
    record_agent = "agent_strict_tenant_record"
    caller_agent = "agent_strict_tenant_caller"

    assert {:ok, operation, _} =
             Embedding.encode_strict_operation(base_input(agent_id: record_agent))

    assert operation.record.agent_id == record_agent

    # Verified admission succeeds; Persistence enforces tenant boundary.
    assert {:error, :tenant_mismatch} =
             Embedding.execute_strict(caller_agent, operation, [])

    assert {:error, :tenant_mismatch} =
             Embedding.reconcile_strict(caller_agent, operation, [])
  end

  test "security regression: strict embedding provenance ignores payload spoof and labels mismatched envelopes hostile" do
    spoofed_payload = %{
      "content" => "payload with spoof",
      "model_id" => "evil/model",
      "provider" => "evil",
      "taint" => %{"level" => "trusted"},
      "provenance" => %{"forged" => true}
    }

    input =
      base_input(
        payload: spoofed_payload,
        model_evidence: {:provider_model, "honest", "model"}
      )

    assert {:ok, operation, view} = Embedding.encode_strict_operation(input)
    assert operation.record.model_id == "honest/model"
    refute operation.record.model_id == "evil/model"
    assert view.model_id == "honest/model"
    assert view.body["model_id"] == "evil/model"
    assert view.provenance_status == :verified

    assert {:ok, decoded} = Embedding.decode_strict_record(operation.record)
    assert decoded.provenance_status == :verified
    assert decoded.taint == trusted_taint()

    mismatched = mismatched_body_provenance_record!(operation.record)

    assert {:ok, hostile} = Embedding.decode_strict_record(mismatched)
    assert hostile.provenance_status == :invalid_durable_provenance
    assert hostile.taint == TaintEnvelope.invalid_fallback()
    assert hostile.taint.source == "invalid_durable_provenance"
    assert hostile.taint.level == :hostile

    descriptor_mismatch = descriptor_mismatched_record!(operation.record)
    assert {:ok, desc_hostile} = Embedding.decode_strict_record(descriptor_mismatch)
    assert desc_hostile.provenance_status == :invalid_durable_provenance
    assert desc_hostile.taint.level == :hostile

    legacy = plain_record!(%{"content" => "legacy unlabeled"})
    assert {:ok, unlabeled} = Embedding.decode_strict_record(legacy)
    assert unlabeled.provenance_status == :legacy_unlabeled
    assert unlabeled.taint == TaintEnvelope.missing_fallback()
    refute unlabeled.provenance_status == :verified
  end

  defp base_input(overrides \\ []) do
    overrides = Map.new(overrides)

    Map.merge(
      %{
        kind: :insert,
        id: "vec_boundary_1",
        agent_id: "agent_boundary_test",
        source_namespace: "memory",
        source_key: "boundary-1",
        payload: %{"content" => "boundary content"},
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
      source: "embedding_boundary_test",
      chain: []
    }
  end

  defp unit_vector do
    [1.0 | List.duplicate(0.0, VectorRecord.dimensions() - 1)]
  end

  defp plain_record!(payload, overrides \\ []) do
    overrides = Map.new(overrides)
    {:ok, payload_digest} = VectorRecord.payload_digest(payload)
    vector = unit_vector()
    {:ok, vector_digest} = VectorRecord.vector_digest(vector)

    attrs =
      Map.merge(
        %{
          id: "vec_legacy_plain",
          agent_id: "agent_boundary_test",
          source_namespace: "memory",
          source_key: "legacy-plain",
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
        },
        overrides
      )

    {:ok, record} = VectorRecord.new(attrs)
    record
  end

  defp mismatched_body_provenance_record!(record) do
    body = record.payload["body"]

    wrong_projection = %{
      "body" => %{"content" => "not the real body"},
      "descriptor" => %{
        "model_id" => record.model_id,
        "dimensions" => record.dimensions,
        "encoding" => "ieee754_float32_be_v1",
        "category" => record.category,
        "vector_digest" => record.vector_digest
      }
    }

    assert {:ok, envelope} = TaintEnvelope.new(wrong_projection, trusted_taint())
    assert {:ok, envelope_map} = TaintEnvelope.to_map(envelope)

    payload = %{
      "kind" => "arbor_memory_embedding",
      "version" => 1,
      "body" => body,
      "provenance" => envelope_map
    }

    rebuild_record!(record, payload: payload)
  end

  defp descriptor_mismatched_record!(record) do
    # Authoritative model_id no longer matches the envelope-bound descriptor.
    rebuild_record!(record, model_id: "other/model-v9")
  end

  defp rebuild_record!(record, overrides) do
    attrs = Map.merge(Map.from_struct(record), Map.new(overrides))
    {:ok, payload_digest} = VectorRecord.payload_digest(attrs.payload)
    {:ok, vector_digest} = VectorRecord.vector_digest(attrs.vector)

    {:ok, rebuilt} =
      VectorRecord.new(
        Map.merge(attrs, %{
          payload_digest: payload_digest,
          vector_digest: vector_digest
        })
      )

    rebuilt
  end
end
