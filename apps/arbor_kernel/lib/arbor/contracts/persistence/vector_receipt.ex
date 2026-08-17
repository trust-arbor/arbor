defmodule Arbor.Contracts.Persistence.VectorReceipt do
  @moduledoc """
  Immutable result of one vector operation.

  A receipt retains the operation fingerprint and the exact committed row
  state. Batch receipts retain every child receipt in submission order, so an
  original result remains reconcilable after later updates change the live row.
  """

  use TypedStruct

  alias Arbor.Contracts.Persistence.{
    VectorOperation,
    VectorRecord,
    VectorValidation
  }

  @single_fields [:operation, :record]
  @batch_fields [:operation, :receipts]
  @input_fields Enum.uniq(@single_fields ++ @batch_fields)
  @attribute_aliases Map.new(@input_fields, fn key -> {key, key} end)
                     |> Map.merge(
                       Map.new(@input_fields, fn key -> {Atom.to_string(key), key} end)
                     )
  @single_kinds [:insert, :update, :delete, :reinsert]
  @batch_fixed_bytes 16
  @receipt_fixed_bytes 73

  @derive {Jason.Encoder, only: [:operation_fingerprint, :kind, :record, :receipts]}
  typedstruct enforce: true do
    @typedoc "An exact committed row or ordered batch result"

    field(:operation_fingerprint, String.t())
    field(:kind, VectorOperation.kind())
    field(:record, VectorRecord.t() | nil)
    field(:receipts, [t()])
  end

  @doc "Constructs a receipt and validates it against the original operation."
  @spec new(map() | list()) :: {:ok, t()} | {:error, :invalid_vector_receipt}
  def new(attrs) do
    case VectorValidation.normalize_attrs(attrs, @attribute_aliases, @single_fields) do
      {:ok, normalized} -> build_single(normalized)
      :error -> build_batch_attrs(attrs)
    end
  rescue
    _error -> invalid()
  catch
    _kind, _reason -> invalid()
  end

  @doc "Revalidates the bounded structure of a receipt."
  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_vector_receipt}
  def validate(%__MODULE__{kind: :batch} = receipt) do
    with true <- is_nil(receipt.record),
         true <- VectorValidation.valid_digest?(receipt.operation_fingerprint),
         {:ok, receipts} <- validate_receipt_list(receipt.receipts),
         true <- receipts == receipt.receipts,
         true <- receipt.operation_fingerprint == batch_fingerprint(receipts) do
      {:ok, receipt}
    else
      _invalid -> invalid()
    end
  end

  def validate(%__MODULE__{kind: kind, record: %VectorRecord{} = record, receipts: []} = receipt)
      when kind in @single_kinds do
    with true <- VectorValidation.valid_digest?(receipt.operation_fingerprint),
         {:ok, ^record} <- VectorRecord.validate(record) do
      {:ok, receipt}
    else
      _invalid -> invalid()
    end
  end

  def validate(_receipt), do: invalid()

  @doc "Validates that a receipt is the exact result of the supplied operation."
  @spec validate_for_operation(term(), term()) ::
          {:ok, t()} | {:error, :invalid_vector_receipt}
  def validate_for_operation(%__MODULE__{} = receipt, %VectorOperation{kind: :batch} = operation) do
    case new(%{operation: operation, receipts: receipt.receipts}) do
      {:ok, ^receipt} -> {:ok, receipt}
      _invalid -> invalid()
    end
  end

  def validate_for_operation(%__MODULE__{} = receipt, %VectorOperation{} = operation) do
    case new(%{operation: operation, record: receipt.record}) do
      {:ok, ^receipt} -> {:ok, receipt}
      _invalid -> invalid()
    end
  end

  def validate_for_operation(_receipt, _operation), do: invalid()

  @doc "Returns true only when a receipt is canonical and matches an operation."
  @spec valid_for_operation?(term(), term()) :: boolean()
  def valid_for_operation?(receipt, operation) do
    match?({:ok, %__MODULE__{}}, validate_for_operation(receipt, operation))
  end

  defp build_batch_attrs(attrs) do
    case VectorValidation.normalize_attrs(attrs, @attribute_aliases, @batch_fields) do
      {:ok, normalized} -> build_batch(normalized)
      :error -> invalid()
    end
  end

  defp build_single(%{operation: operation, record: result}) do
    with {:ok, %VectorOperation{kind: kind} = operation} <- VectorOperation.validate(operation),
         true <- kind in @single_kinds,
         {:ok, result} <- VectorRecord.validate(result),
         true <- VectorRecord.same_value?(operation.record, result),
         :ok <- validate_result_fence(operation, result) do
      {:ok,
       %__MODULE__{
         operation_fingerprint: operation.fingerprint,
         kind: kind,
         record: result,
         receipts: []
       }}
    else
      _invalid -> invalid()
    end
  end

  defp build_single(_attrs), do: invalid()

  defp build_batch(%{operation: operation, receipts: receipts}) do
    with {:ok, %VectorOperation{kind: :batch} = operation} <-
           VectorOperation.validate(operation),
         {:ok, receipts} <- validate_batch_receipts(operation.operations, receipts, []) do
      {:ok,
       %__MODULE__{
         operation_fingerprint: operation.fingerprint,
         kind: :batch,
         record: nil,
         receipts: receipts
       }}
    else
      _invalid -> invalid()
    end
  end

  defp build_batch(_attrs), do: invalid()

  defp validate_result_fence(%VectorOperation{kind: :insert}, %VectorRecord{} = result) do
    if result.generation == 1 and result.revision == 1 and not result.tombstone,
      do: :ok,
      else: {:error, :invalid_fence}
  end

  defp validate_result_fence(
         %VectorOperation{
           kind: :update,
           expected_generation: generation,
           expected_revision: revision
         },
         %VectorRecord{} = result
       ) do
    if result.generation == generation and result.revision == revision + 1 and
         not result.tombstone,
       do: :ok,
       else: {:error, :invalid_fence}
  end

  defp validate_result_fence(
         %VectorOperation{
           kind: :delete,
           expected_generation: generation,
           expected_revision: revision
         },
         %VectorRecord{} = result
       ) do
    if result.generation == generation and result.revision == revision + 1 and result.tombstone,
      do: :ok,
      else: {:error, :invalid_fence}
  end

  defp validate_result_fence(
         %VectorOperation{
           kind: :reinsert,
           expected_generation: generation
         },
         %VectorRecord{} = result
       ) do
    if result.generation == generation + 1 and result.revision == 1 and
         not result.tombstone,
       do: :ok,
       else: {:error, :invalid_fence}
  end

  defp validate_batch_receipts([], [], receipts), do: {:ok, Enum.reverse(receipts)}

  defp validate_batch_receipts(
         [operation | operations],
         [%__MODULE__{} = receipt | receipts],
         validated
       ) do
    case validate_for_operation(receipt, operation) do
      {:ok, receipt} -> validate_batch_receipts(operations, receipts, [receipt | validated])
      {:error, :invalid_vector_receipt} -> invalid()
    end
  end

  defp validate_batch_receipts(_operations, _receipts, _validated), do: invalid()

  defp validate_receipt_list(receipts) when is_list(receipts) do
    validate_receipt_list(receipts, [], 0, @batch_fixed_bytes)
  end

  defp validate_receipt_list(_receipts), do: invalid()

  defp validate_receipt_list([], receipts, count, _bytes) when count > 0,
    do: {:ok, Enum.reverse(receipts)}

  defp validate_receipt_list(
         [%__MODULE__{kind: kind} = receipt | rest],
         receipts,
         count,
         bytes
       )
       when kind in @single_kinds do
    if count >= VectorOperation.max_batch_operations() do
      invalid()
    else
      with {:ok, ^receipt} <- validate(receipt),
           {:ok, record_bytes} <- VectorRecord.transport_size_bytes(receipt.record),
           next_bytes =
             bytes + 4 + @receipt_fixed_bytes + byte_size(Atom.to_string(kind)) + record_bytes,
           true <- next_bytes <= VectorOperation.limits().max_batch_bytes do
        validate_receipt_list(rest, [receipt | receipts], count + 1, next_bytes)
      else
        _invalid -> invalid()
      end
    end
  end

  defp validate_receipt_list([%__MODULE__{} | _rest], _receipts, _count, _bytes),
    do: invalid()

  defp validate_receipt_list(_improper, _receipts, _count, _bytes), do: invalid()

  defp batch_fingerprint(receipts) do
    VectorValidation.fingerprint([
      "batch",
      Integer.to_string(length(receipts))
      | Enum.map(receipts, & &1.operation_fingerprint)
    ])
  end

  defp invalid, do: {:error, :invalid_vector_receipt}
end
