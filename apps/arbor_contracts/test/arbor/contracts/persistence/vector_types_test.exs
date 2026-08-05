defmodule Arbor.Contracts.Persistence.VectorTypesTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Persistence.{
    VectorMatch,
    VectorOperation,
    VectorReceipt,
    VectorRecord,
    VectorValidation
  }

  @moduletag :fast
  @sha256_abc "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

  describe "VectorRecord" do
    test "pins the SHA-256 primitive to a known vector" do
      assert VectorValidation.sha256("abc") == @sha256_abc
    end

    test "constructs the exact logical identity and descriptor" do
      assert {:ok, record} = VectorRecord.new(record_attrs())

      assert VectorRecord.identity(record) == {"agent_alpha", "goals", "goal_1"}
      assert record.dimensions == 768
      assert record.encoding == :ieee754_float32_be_v1
      assert record.category == "goal"
      assert record.payload == %{"content" => "remember this", "rank" => 1}
      assert VectorRecord.valid?(record)
    end

    test "normalizes finite values to exact big-endian float32 bytes" do
      vector = [0.1, -0.0, 1.0] ++ List.duplicate(0.25, 765)
      assert {:ok, record} = VectorRecord.new(record_attrs(vector: vector))
      assert {:ok, bytes} = VectorRecord.vector_bytes(vector)

      <<expected_tenth::float-size(32)>> = <<0.1::float-size(32)>>
      assert Enum.at(record.vector, 0) == expected_tenth
      assert Enum.at(record.vector, 1) == 0.0

      assert binary_part(bytes, 0, 12) ==
               <<0.1::float-size(32), 0::unsigned-size(32), 1.0::float-size(32)>>

      assert {:ok, record.vector_digest} == VectorRecord.vector_digest(record.vector)
    end

    test "rejects NaN/Inf representations and values that overflow float32" do
      for invalid <- [:nan, :positive_infinity, :negative_infinity, 3.5e38, -3.5e38] do
        vector = [invalid | List.duplicate(0.0, 767)]
        assert {:error, :invalid_vector} = VectorRecord.normalize_vector(vector)
      end
    end

    test "regression: rejects normalized zero-norm records and queries but accepts signed vectors" do
      zero_vector = List.duplicate(0.0, VectorRecord.dimensions())
      zero_bytes = :binary.copy(<<0>>, VectorRecord.dimensions() * 4)

      zero_attrs =
        record_attrs()
        |> Map.put(:vector, zero_vector)
        |> Map.put(:vector_digest, VectorValidation.sha256(zero_bytes))

      assert {:error, :invalid_vector} = VectorRecord.normalize_vector(zero_vector)
      assert {:error, :invalid_vector} = VectorRecord.vector_digest(zero_vector)
      assert {:error, :invalid_vector_record} = VectorRecord.new(zero_attrs)

      signed_vector = [-1.0, 1.0 | List.duplicate(0.0, 766)]
      assert {:ok, ^signed_vector} = VectorRecord.normalize_vector(signed_vector)

      assert {:ok, %VectorRecord{vector: ^signed_vector}} =
               VectorRecord.new(record_attrs(vector: signed_vector))
    end

    test "rejects short, oversized, and improper vectors" do
      short = List.duplicate(0.0, 767)
      oversized = List.duplicate(0.0, 769)
      improper = List.duplicate(0.0, 767) ++ [0.0 | :improper]

      for vector <- [short, oversized, improper] do
        attrs = record_attrs() |> Map.put(:vector, vector)
        assert {:error, :invalid_vector_record} = VectorRecord.new(attrs)
      end
    end

    test "canonical payload validation rejects invalid UTF-8, depth, count, and byte overflow" do
      payload_limits = VectorRecord.limits().payload
      too_deep = Enum.reduce(0..payload_limits.max_depth, "leaf", fn _, value -> [value] end)
      too_many = List.duplicate("item", payload_limits.max_array_items + 1)
      too_large = String.duplicate("x", payload_limits.max_string_bytes + 1)

      for payload <- [<<255>>, too_deep, too_many, too_large] do
        assert {:error, _reason} = VectorRecord.payload_digest(payload)
      end

      assert {:error, _reason} = VectorRecord.payload_digest(%{:same => 1, "same" => 1})
    end

    test "rejects malformed identifiers, descriptors, and digest values" do
      max = VectorRecord.limits()

      invalid_overrides = [
        [agent_id: <<255>>],
        [source_namespace: String.duplicate("n", max.source_namespace_bytes + 1)],
        [source_key: "  "],
        [model_id: String.duplicate("m", max.model_id_bytes + 1)],
        [dimensions: 1_536],
        [encoding: :float32_le],
        [category: String.duplicate("c", max.category_bytes + 1)],
        [payload_digest: String.duplicate("A", 64)],
        [vector_digest: String.duplicate("0", 64)]
      ]

      for overrides <- invalid_overrides do
        assert {:error, :invalid_vector_record} = VectorRecord.new(record_attrs(overrides))
      end
    end

    test "rejects unknown fields, mixed alias collisions, and improper attribute lists" do
      attrs = record_attrs()

      assert {:error, :invalid_vector_record} =
               attrs
               |> Map.delete(:category)
               |> Map.put("agent_id", attrs.agent_id)
               |> VectorRecord.new()

      assert {:error, :invalid_vector_record} =
               attrs
               |> Map.delete(:category)
               |> Map.put(:caller_metadata, %{"taint" => "trusted"})
               |> VectorRecord.new()

      improper = Enum.to_list(attrs) ++ [{:category, "goal"} | :improper]
      assert {:error, :invalid_vector_record} = VectorRecord.new(improper)
    end

    test "accepts exact string-key aliases without allocating atoms" do
      string_attrs = Map.new(record_attrs(), fn {key, value} -> {Atom.to_string(key), value} end)

      assert {:ok, %VectorRecord{} = record} = VectorRecord.new(string_attrs)
      assert record.encoding == :ieee754_float32_be_v1
    end

    test "enforces the signed BIGINT fence boundary" do
      max = VectorRecord.max_fence_value()

      assert {:ok, %VectorRecord{generation: ^max, revision: ^max}} =
               VectorRecord.new(record_attrs(generation: max, revision: max, tombstone: true))

      for overrides <- [
            [generation: max + 1],
            [revision: max + 1],
            [generation: -1],
            [revision: -1]
          ] do
        assert {:error, :invalid_vector_record} = VectorRecord.new(record_attrs(overrides))
      end
    end

    test "revalidation catches directly forged normalized fields" do
      record = record!()
      forged = %{record | vector: [0.1 | tl(record.vector)]}

      assert {:error, :invalid_vector_record} = VectorRecord.validate(forged)
    end
  end

  describe "VectorOperation" do
    test "fingerprints are deterministic and bind every mutable input" do
      record = record!()
      insert = operation!(:insert, record)
      same = operation!("insert", record)

      assert insert.fingerprint == same.fingerprint
      assert insert.fingerprint =~ ~r/\A[0-9a-f]{64}\z/

      changed_records = [
        record!(agent_id: "agent_beta"),
        record!(source_namespace: "thinking"),
        record!(source_key: "goal_2"),
        record!(id: "vec_row_2"),
        record!(payload: %{"content" => "different"}),
        record!(vector: [0.5 | List.duplicate(0.25, 767)]),
        record!(model_id: "provider/model-v2"),
        record!(category: "thought")
      ]

      for changed <- changed_records do
        refute operation!(:insert, changed).fingerprint == insert.fingerprint
      end

      current = record!(generation: 7, revision: 9)
      update = operation!(:update, current)
      delete = operation!(:delete, current)
      refute update.fingerprint == delete.fingerprint

      next_revision = rebuild_record!(current, revision: 10)
      refute operation!(:update, next_revision).fingerprint == update.fingerprint
    end

    test "validates insert, update, delete, and reinsert fences" do
      fresh = record!()
      current = record!(generation: 3, revision: 4)

      assert {:ok, %VectorOperation{kind: :insert}} =
               VectorOperation.new(single_operation_attrs(:insert, fresh))

      for kind <- [:update, :delete, :reinsert] do
        assert {:ok, %VectorOperation{kind: ^kind}} =
                 VectorOperation.new(single_operation_attrs(kind, current))
      end

      assert {:error, :invalid_vector_operation} =
               VectorOperation.new(single_operation_attrs(:insert, current))

      assert {:error, :invalid_vector_operation} =
               VectorOperation.new(
                 single_operation_attrs(:update, current)
                 |> Map.put(:expected_revision, 3)
               )
    end

    test "rejects fence increments that exceed signed BIGINT" do
      max = VectorRecord.max_fence_value()
      max_revision = record!(generation: 1, revision: max)
      max_generation = record!(generation: max, revision: 1)

      for kind <- [:update, :delete] do
        assert {:error, :invalid_vector_operation} =
                 VectorOperation.new(single_operation_attrs(kind, max_revision))
      end

      assert {:error, :invalid_vector_operation} =
               VectorOperation.new(single_operation_attrs(:reinsert, max_generation))
    end

    test "rejects closed-enum misses, mixed aliases, improper attrs, and forged fingerprints" do
      record = record!()
      attrs = single_operation_attrs(:insert, record)

      assert {:error, :invalid_vector_operation} =
               VectorOperation.new(Map.put(attrs, :kind, "upsert"))

      collision =
        attrs
        |> Map.delete(:expected_revision)
        |> Map.put("kind", "insert")

      assert {:error, :invalid_vector_operation} = VectorOperation.new(collision)
      assert {:error, :invalid_vector_operation} = VectorOperation.new([{:kind, :insert} | :tail])

      operation = operation!(:insert, record)
      forged = %{operation | fingerprint: String.duplicate("f", 64)}
      assert {:error, :invalid_vector_operation} = VectorOperation.validate(forged)
    end

    test "batch is ordered, bounded, tenant-scoped, unique, and never nested" do
      first = operation!(:insert, record!(source_key: "one"))
      second = operation!(:insert, record!(source_key: "two"))

      assert {:ok, batch} = VectorOperation.new(%{kind: :batch, operations: [first, second]})
      assert batch.operations == [first, second]

      assert {:ok, reversed} =
               VectorOperation.new(%{kind: "batch", operations: [second, first]})

      refute batch.fingerprint == reversed.fingerprint

      assert {:error, :invalid_vector_operation} =
               VectorOperation.new(%{kind: :batch, operations: [first, first]})

      other_agent = operation!(:insert, record!(agent_id: "agent_beta", source_key: "three"))

      assert {:error, :invalid_vector_operation} =
               VectorOperation.new(%{kind: :batch, operations: [first, other_agent]})

      assert {:error, :invalid_vector_operation} =
               VectorOperation.new(%{kind: :batch, operations: [batch]})

      assert {:error, :invalid_vector_operation} =
               VectorOperation.new(%{kind: :batch, operations: [first | :improper]})
    end

    test "accepts the exact batch ceiling and rejects one more" do
      max = VectorOperation.max_batch_operations()

      operations =
        Enum.map(1..(max + 1), fn index ->
          operation!(:insert, record!(source_key: "item_#{index}"))
        end)

      assert {:ok, %VectorOperation{kind: :batch}} =
               VectorOperation.new(%{kind: :batch, operations: Enum.take(operations, max)})

      assert {:error, :invalid_vector_operation} =
               VectorOperation.new(%{kind: :batch, operations: operations})
    end

    test "rejects a count-valid batch above the aggregate transport-byte ceiling" do
      operations = oversized_batch_operations()

      assert length(operations) < VectorOperation.limits().max_batch_operations
      assert aggregate_operation_bytes(operations) > VectorOperation.limits().max_batch_bytes

      assert {:error, :invalid_vector_operation} =
               VectorOperation.new(%{kind: :batch, operations: operations})
    end
  end

  describe "VectorReceipt" do
    test "encodes every fence transition and rejects impossible outcomes" do
      fresh = record!()
      insert = operation!(:insert, fresh)
      inserted = rebuild_record!(fresh, generation: 1, revision: 1)
      assert {:ok, insert_receipt} = VectorReceipt.new(%{operation: insert, record: inserted})
      assert VectorReceipt.valid_for_operation?(insert_receipt, insert)

      update = operation!(:update, inserted)
      updated = rebuild_record!(inserted, revision: 2)
      assert {:ok, _receipt} = VectorReceipt.new(%{operation: update, record: updated})

      delete = operation!(:delete, updated)
      tombstone = rebuild_record!(updated, revision: 3, tombstone: true)
      assert {:ok, delete_receipt} = VectorReceipt.new(%{operation: delete, record: tombstone})
      assert delete_receipt.record.tombstone

      reinsert_input = rebuild_record!(tombstone, tombstone: false)
      reinsert = operation!(:reinsert, reinsert_input)
      reinserted = rebuild_record!(reinsert_input, generation: 2, revision: 1)
      assert {:ok, _receipt} = VectorReceipt.new(%{operation: reinsert, record: reinserted})

      assert {:error, :invalid_vector_receipt} =
               VectorReceipt.new(%{operation: update, record: inserted})

      changed_id = rebuild_record!(updated, id: "different_stable_id")

      assert {:error, :invalid_vector_receipt} =
               VectorReceipt.new(%{operation: update, record: changed_id})
    end

    test "retains an original exact result after later updates" do
      inserted = record!(generation: 1, revision: 1)
      first_result = rebuild_record!(inserted, revision: 2, payload: %{"content" => "v2"})

      first_operation =
        operation!(:update, rebuild_record!(inserted, payload: first_result.payload))

      assert {:ok, first_receipt} =
               VectorReceipt.new(%{operation: first_operation, record: first_result})

      second_result = rebuild_record!(first_result, revision: 3, payload: %{"content" => "v3"})

      second_operation =
        operation!(:update, rebuild_record!(first_result, payload: second_result.payload))

      assert {:ok, _second_receipt} =
               VectorReceipt.new(%{operation: second_operation, record: second_result})

      assert first_receipt.operation_fingerprint == first_operation.fingerprint
      assert first_receipt.record.revision == 2
      assert first_receipt.record.payload == %{"content" => "v2"}
    end

    test "batch receipt preserves ordered child receipts" do
      first = operation!(:insert, record!(source_key: "one"))
      second = operation!(:insert, record!(source_key: "two"))
      batch = batch!([first, second])

      first_receipt = receipt!(first, rebuild_record!(first.record, generation: 1, revision: 1))

      second_receipt =
        receipt!(second, rebuild_record!(second.record, generation: 1, revision: 1))

      assert {:ok, receipt} =
               VectorReceipt.new(%{
                 operation: batch,
                 receipts: [first_receipt, second_receipt]
               })

      assert receipt.operation_fingerprint == batch.fingerprint
      assert receipt.receipts == [first_receipt, second_receipt]

      assert {:error, :invalid_vector_receipt} =
               VectorReceipt.new(%{
                 operation: batch,
                 receipts: [second_receipt, first_receipt]
               })
    end

    test "standalone validation rejects forged nested batch receipts" do
      operation = operation!(:insert, record!())
      batch = batch!([operation])
      child = receipt!(operation, rebuild_record!(operation.record, generation: 1, revision: 1))
      assert {:ok, batch_receipt} = VectorReceipt.new(%{operation: batch, receipts: [child]})

      nested = %VectorReceipt{
        operation_fingerprint: batch.fingerprint,
        kind: :batch,
        record: nil,
        receipts: [batch_receipt]
      }

      assert {:error, :invalid_vector_receipt} = VectorReceipt.validate(nested)
    end

    test "standalone validation rejects a forged batch parent fingerprint" do
      operation = operation!(:insert, record!())
      batch = batch!([operation])
      child = receipt!(operation, rebuild_record!(operation.record, generation: 1, revision: 1))
      assert {:ok, batch_receipt} = VectorReceipt.new(%{operation: batch, receipts: [child]})

      forged = %{batch_receipt | operation_fingerprint: String.duplicate("f", 64)}

      assert {:error, :invalid_vector_receipt} = VectorReceipt.validate(forged)
    end

    test "standalone validation rejects a forged byte-oversized batch receipt" do
      operations = oversized_batch_operations()
      assert aggregate_operation_bytes(operations) > VectorOperation.limits().max_batch_bytes

      receipts =
        Enum.map(operations, fn operation ->
          result = rebuild_record!(operation.record, generation: 1, revision: 1)
          receipt!(operation, result)
        end)

      forged = %VectorReceipt{
        operation_fingerprint: String.duplicate("a", 64),
        kind: :batch,
        record: nil,
        receipts: receipts
      }

      assert {:error, :invalid_vector_receipt} = VectorReceipt.validate(forged)
    end

    test "rejects atom/string alias collisions and malformed receipt lists" do
      operation = operation!(:insert, record!())
      result = rebuild_record!(operation.record, generation: 1, revision: 1)

      assert {:error, :invalid_vector_receipt} =
               VectorReceipt.new([
                 {:operation, operation},
                 {"operation", operation},
                 {:record, result}
               ])

      batch = batch!([operation])

      assert {:error, :invalid_vector_receipt} =
               VectorReceipt.new(%{
                 operation: batch,
                 receipts: [receipt!(operation, result) | :tail]
               })
    end
  end

  describe "VectorMatch" do
    test "normalizes a finite score and retains the complete verifiable record" do
      record = record!(generation: 1, revision: 1)
      assert {:ok, match} = VectorMatch.new(%{"record" => record, "similarity" => 0.9})
      assert match.record == record
      assert VectorMatch.valid?(match)
      assert {:ok, record.vector_digest} == VectorRecord.vector_digest(match.record.vector)
    end

    test "rejects tombstones, out-of-range/non-finite scores, mixed keys, and forged scores" do
      record = record!(generation: 1, revision: 1)
      tombstone = rebuild_record!(record, tombstone: true)

      for attrs <- [
            %{record: tombstone, similarity: 0.5},
            %{record: record, similarity: 1.01},
            %{record: record, similarity: -1.01},
            %{record: record, similarity: :nan},
            %{record: record, similarity: :positive_infinity},
            [{:record, record}, {"record", record}, {:similarity, 0.5}]
          ] do
        assert {:error, :invalid_vector_match} = VectorMatch.new(attrs)
      end

      assert {:ok, match} = VectorMatch.new(%{record: record, similarity: 0.5})
      assert {:error, :invalid_vector_match} = VectorMatch.validate(%{match | similarity: 0.6})
    end
  end

  defp vector, do: List.duplicate(0.25, VectorRecord.dimensions())

  defp record_attrs(overrides \\ []) do
    overrides = Map.new(overrides)
    payload = Map.get(overrides, :payload, %{"content" => "remember this", "rank" => 1})
    vector = Map.get(overrides, :vector, vector())
    {:ok, payload_digest} = VectorRecord.payload_digest(payload)
    {:ok, vector_digest} = VectorRecord.vector_digest(vector)

    %{
      id: "vec_row_1",
      agent_id: "agent_alpha",
      source_namespace: "goals",
      source_key: "goal_1",
      payload: payload,
      vector: vector,
      payload_digest: Map.get(overrides, :payload_digest, payload_digest),
      vector_digest: Map.get(overrides, :vector_digest, vector_digest),
      model_id: "provider/model-v1",
      dimensions: VectorRecord.dimensions(),
      encoding: VectorRecord.encoding(),
      category: "goal",
      generation: 0,
      revision: 0,
      tombstone: false
    }
    |> Map.merge(overrides)
  end

  defp record!(overrides \\ []) do
    {:ok, record} = VectorRecord.new(record_attrs(overrides))
    record
  end

  defp rebuild_record!(%VectorRecord{} = record, overrides) do
    overrides = Map.new(overrides)
    attrs = Map.merge(Map.from_struct(record), overrides)
    payload = attrs.payload
    vector = attrs.vector
    {:ok, payload_digest} = VectorRecord.payload_digest(payload)
    {:ok, vector_digest} = VectorRecord.vector_digest(vector)

    attrs =
      attrs
      |> Map.put(:payload_digest, payload_digest)
      |> Map.put(:vector_digest, vector_digest)

    {:ok, rebuilt} = VectorRecord.new(attrs)
    rebuilt
  end

  defp single_operation_attrs(kind, %VectorRecord{} = record) do
    if kind in [:insert, "insert"] do
      %{kind: kind, record: record, expected_generation: nil, expected_revision: nil}
    else
      %{
        kind: kind,
        record: record,
        expected_generation: record.generation,
        expected_revision: record.revision
      }
    end
  end

  defp operation!(kind, %VectorRecord{} = record) do
    {:ok, operation} = VectorOperation.new(single_operation_attrs(kind, record))
    operation
  end

  defp batch!(operations) do
    {:ok, operation} = VectorOperation.new(%{kind: :batch, operations: operations})
    operation
  end

  defp receipt!(operation, result) do
    {:ok, receipt} = VectorReceipt.new(%{operation: operation, record: result})
    receipt
  end

  defp oversized_batch_operations do
    payload = List.duplicate(String.duplicate("x", 60_000), 2)

    Enum.map(1..36, fn index ->
      operation!(:insert, record!(source_key: "large_#{index}", payload: payload))
    end)
  end

  defp aggregate_operation_bytes(operations) do
    Enum.reduce(operations, 16, fn operation, total ->
      {:ok, bytes} = VectorOperation.transport_size_bytes(operation)
      total + 4 + bytes
    end)
  end
end
