defmodule Arbor.Persistence.VectorStore.Ecto.Codec do
  @moduledoc false

  alias Arbor.Contracts.Persistence.{VectorOperation, VectorReceipt, VectorRecord}

  @format_version 1
  @max_ledger_json_bytes 8_388_608
  @max_batch_operations VectorOperation.max_batch_operations()
  @vector_bytes VectorRecord.dimensions() * 4

  @spec encode_operation(VectorOperation.t()) :: {:ok, binary()} | {:error, :invalid_codec}
  def encode_operation(%VectorOperation{} = operation) do
    with {:ok, ^operation} <- VectorOperation.validate(operation),
         {:ok, encoded} <- Jason.encode(operation_map(operation)),
         true <- bounded_json?(encoded) do
      {:ok, encoded}
    else
      _invalid -> invalid()
    end
  rescue
    _error -> invalid()
  catch
    _kind, _reason -> invalid()
  end

  def encode_operation(_operation), do: invalid()

  @spec decode_operation(term()) :: {:ok, VectorOperation.t()} | {:error, :invalid_codec}
  def decode_operation(encoded) when is_binary(encoded) do
    with true <- bounded_json?(encoded),
         {:ok, decoded} <- Jason.decode(encoded),
         {:ok, operation} <- operation_from_map(decoded) do
      {:ok, operation}
    else
      _invalid -> invalid()
    end
  rescue
    _error -> invalid()
  catch
    _kind, _reason -> invalid()
  end

  def decode_operation(_encoded), do: invalid()

  @spec encode_receipt(VectorReceipt.t(), VectorOperation.t()) ::
          {:ok, binary()} | {:error, :invalid_codec}
  def encode_receipt(%VectorReceipt{} = receipt, %VectorOperation{} = operation) do
    with {:ok, ^receipt} <- VectorReceipt.validate_for_operation(receipt, operation),
         {:ok, encoded} <- Jason.encode(receipt_map(receipt)),
         true <- bounded_json?(encoded) do
      {:ok, encoded}
    else
      _invalid -> invalid()
    end
  rescue
    _error -> invalid()
  catch
    _kind, _reason -> invalid()
  end

  def encode_receipt(_receipt, _operation), do: invalid()

  @spec decode_receipt(term(), VectorOperation.t()) ::
          {:ok, VectorReceipt.t()} | {:error, :invalid_codec}
  def decode_receipt(encoded, %VectorOperation{} = operation) when is_binary(encoded) do
    with true <- bounded_json?(encoded),
         {:ok, decoded} <- Jason.decode(encoded),
         {:ok, receipt} <- receipt_from_map(decoded, operation),
         {:ok, ^receipt} <- VectorReceipt.validate_for_operation(receipt, operation) do
      {:ok, receipt}
    else
      _invalid -> invalid()
    end
  rescue
    _error -> invalid()
  catch
    _kind, _reason -> invalid()
  end

  def decode_receipt(_encoded, _operation), do: invalid()

  @spec vector_from_bytes(term()) :: {:ok, [float()]} | {:error, :invalid_codec}
  def vector_from_bytes(bytes)
      when is_binary(bytes) and byte_size(bytes) == @vector_bytes do
    with {:ok, vector} <- collect_vector(bytes, []),
         {:ok, ^bytes} <- VectorRecord.vector_bytes(vector) do
      {:ok, vector}
    else
      _invalid -> invalid()
    end
  end

  def vector_from_bytes(_bytes), do: invalid()

  @spec digest(iodata()) :: String.t()
  def digest(data) do
    :crypto.hash(:sha256, data)
    |> Base.encode16(case: :lower)
  end

  defp operation_map(%VectorOperation{kind: :batch} = operation) do
    %{
      "version" => @format_version,
      "kind" => "batch",
      "operations" => Enum.map(operation.operations, &operation_map/1)
    }
  end

  defp operation_map(%VectorOperation{} = operation) do
    %{
      "version" => @format_version,
      "kind" => Atom.to_string(operation.kind),
      "record" => record_map(operation.record),
      "expected_generation" => operation.expected_generation,
      "expected_revision" => operation.expected_revision
    }
  end

  defp operation_from_map(
         %{"version" => @format_version, "kind" => "batch", "operations" => operations} = map
       )
       when map_size(map) == 3 and is_list(operations) do
    with {:ok, operations} <- decode_operations(operations, [], 0),
         {:ok, operation} <- VectorOperation.new(%{kind: :batch, operations: operations}) do
      {:ok, operation}
    else
      _invalid -> invalid()
    end
  end

  defp operation_from_map(
         %{
           "version" => @format_version,
           "kind" => kind,
           "record" => record,
           "expected_generation" => expected_generation,
           "expected_revision" => expected_revision
         } = map
       )
       when map_size(map) == 5 do
    with {:ok, record} <- record_from_map(record),
         {:ok, operation} <-
           VectorOperation.new(%{
             kind: kind,
             record: record,
             expected_generation: expected_generation,
             expected_revision: expected_revision
           }) do
      {:ok, operation}
    else
      _invalid -> invalid()
    end
  end

  defp operation_from_map(_map), do: invalid()

  defp decode_operations([], operations, count) when count > 0,
    do: {:ok, Enum.reverse(operations)}

  defp decode_operations(_remaining, _operations, count)
       when count >= @max_batch_operations,
       do: invalid()

  defp decode_operations([encoded | rest], operations, count) do
    with {:ok, %VectorOperation{kind: kind} = operation} <- operation_from_map(encoded),
         false <- kind == :batch do
      decode_operations(rest, [operation | operations], count + 1)
    else
      _invalid -> invalid()
    end
  end

  defp decode_operations(_improper, _operations, _count), do: invalid()

  defp receipt_map(%VectorReceipt{kind: :batch} = receipt) do
    %{
      "version" => @format_version,
      "kind" => "batch",
      "operation_fingerprint" => receipt.operation_fingerprint,
      "receipts" => Enum.map(receipt.receipts, &receipt_map/1)
    }
  end

  defp receipt_map(%VectorReceipt{} = receipt) do
    %{
      "version" => @format_version,
      "kind" => Atom.to_string(receipt.kind),
      "operation_fingerprint" => receipt.operation_fingerprint,
      "record" => record_map(receipt.record)
    }
  end

  defp receipt_from_map(
         %{
           "version" => @format_version,
           "kind" => "batch",
           "operation_fingerprint" => fingerprint,
           "receipts" => encoded_receipts
         } = map,
         %VectorOperation{kind: :batch, operations: operations} = operation
       )
       when map_size(map) == 4 and is_list(encoded_receipts) do
    with {:ok, receipts} <- decode_receipts(encoded_receipts, operations, []),
         {:ok, receipt} <- VectorReceipt.new(%{operation: operation, receipts: receipts}),
         true <- receipt.operation_fingerprint == fingerprint do
      {:ok, receipt}
    else
      _invalid -> invalid()
    end
  end

  defp receipt_from_map(
         %{
           "version" => @format_version,
           "kind" => kind,
           "operation_fingerprint" => fingerprint,
           "record" => encoded_record
         } = map,
         %VectorOperation{kind: operation_kind} = operation
       )
       when map_size(map) == 4 and operation_kind != :batch do
    with true <- kind == Atom.to_string(operation_kind),
         true <- fingerprint == operation.fingerprint,
         {:ok, record} <- record_from_map(encoded_record),
         {:ok, receipt} <- VectorReceipt.new(%{operation: operation, record: record}) do
      {:ok, receipt}
    else
      _invalid -> invalid()
    end
  end

  defp receipt_from_map(_map, _operation), do: invalid()

  defp decode_receipts([], [], receipts), do: {:ok, Enum.reverse(receipts)}

  defp decode_receipts([encoded | encoded_rest], [operation | operations], receipts) do
    with {:ok, receipt} <- receipt_from_map(encoded, operation) do
      decode_receipts(encoded_rest, operations, [receipt | receipts])
    end
  end

  defp decode_receipts(_encoded, _operations, _receipts), do: invalid()

  defp record_map(%VectorRecord{} = record) do
    {:ok, payload_bytes} = VectorRecord.canonical_payload_bytes(record.payload)
    {:ok, vector_bytes} = VectorRecord.vector_bytes(record.vector)

    %{
      "id" => record.id,
      "agent_id" => record.agent_id,
      "source_namespace" => record.source_namespace,
      "source_key" => record.source_key,
      "payload_bytes" => Base.encode64(payload_bytes),
      "payload_digest" => record.payload_digest,
      "vector_bytes" => Base.encode64(vector_bytes),
      "vector_digest" => record.vector_digest,
      "model_id" => record.model_id,
      "dimensions" => record.dimensions,
      "encoding" => Atom.to_string(record.encoding),
      "category" => record.category,
      "generation" => record.generation,
      "revision" => record.revision,
      "tombstone" => record.tombstone
    }
  end

  defp record_from_map(
         %{
           "id" => id,
           "agent_id" => agent_id,
           "source_namespace" => source_namespace,
           "source_key" => source_key,
           "payload_bytes" => encoded_payload,
           "payload_digest" => payload_digest,
           "vector_bytes" => encoded_vector,
           "vector_digest" => vector_digest,
           "model_id" => model_id,
           "dimensions" => dimensions,
           "encoding" => encoding,
           "category" => category,
           "generation" => generation,
           "revision" => revision,
           "tombstone" => tombstone
         } = map
       )
       when map_size(map) == 15 do
    with {:ok, payload_bytes} <- decode_base64(encoded_payload),
         {:ok, payload} <- Jason.decode(payload_bytes),
         {:ok, ^payload_bytes} <- VectorRecord.canonical_payload_bytes(payload),
         {:ok, vector_bytes} <- decode_base64(encoded_vector),
         {:ok, vector} <- vector_from_bytes(vector_bytes),
         {:ok, record} <-
           VectorRecord.new(%{
             id: id,
             agent_id: agent_id,
             source_namespace: source_namespace,
             source_key: source_key,
             payload: payload,
             vector: vector,
             payload_digest: payload_digest,
             vector_digest: vector_digest,
             model_id: model_id,
             dimensions: dimensions,
             encoding: encoding,
             category: category,
             generation: generation,
             revision: revision,
             tombstone: tombstone
           }) do
      {:ok, record}
    else
      _invalid -> invalid()
    end
  end

  defp record_from_map(_map), do: invalid()

  defp decode_base64(value) when is_binary(value), do: Base.decode64(value)
  defp decode_base64(_value), do: :error

  defp collect_vector(<<>>, vector), do: {:ok, Enum.reverse(vector)}

  defp collect_vector(<<value::float-size(32), rest::binary>>, vector),
    do: collect_vector(rest, [value | vector])

  defp bounded_json?(encoded),
    do:
      is_binary(encoded) and byte_size(encoded) > 0 and
        byte_size(encoded) <= @max_ledger_json_bytes

  defp invalid, do: {:error, :invalid_codec}
end
