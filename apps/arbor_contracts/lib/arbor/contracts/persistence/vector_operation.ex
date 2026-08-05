defmodule Arbor.Contracts.Persistence.VectorOperation do
  @moduledoc """
  Deterministic mutation intent for the vector store.

  Single-row operations bind the exact logical identity, expected generation
  and revision, stable row id, payload/vector digests, and vector descriptor.
  Batch operations bind an ordered, bounded list of those single-operation
  fingerprints and cannot contain nested batches.
  """

  use TypedStruct

  alias Arbor.Contracts.Persistence.{VectorRecord, VectorValidation}

  @max_batch_operations 100
  @max_batch_bytes 4_194_304
  @batch_fixed_bytes 16
  @operation_fixed_bytes 90
  @single_fields [:kind, :record, :expected_generation, :expected_revision]
  @batch_fields [:kind, :operations]
  @input_fields Enum.uniq(@single_fields ++ @batch_fields)
  @attribute_aliases Map.new(@input_fields, fn key -> {key, key} end)
                     |> Map.merge(
                       Map.new(@input_fields, fn key -> {Atom.to_string(key), key} end)
                     )
  @kind_aliases %{
    :insert => :insert,
    "insert" => :insert,
    :update => :update,
    "update" => :update,
    :delete => :delete,
    "delete" => :delete,
    :reinsert => :reinsert,
    "reinsert" => :reinsert,
    :batch => :batch,
    "batch" => :batch
  }

  @type single_kind :: :insert | :update | :delete | :reinsert
  @type kind :: single_kind() | :batch

  @derive Jason.Encoder
  typedstruct enforce: true do
    @typedoc "A bounded vector mutation or atomic mutation batch"

    field(:kind, kind())
    field(:record, VectorRecord.t() | nil)
    field(:expected_generation, pos_integer() | nil)
    field(:expected_revision, pos_integer() | nil)
    field(:operations, [t()])
    field(:fingerprint, String.t())
  end

  @doc "Constructs a single mutation or first-class bounded batch."
  @spec new(map() | list()) :: {:ok, t()} | {:error, :invalid_vector_operation}
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

  @doc "Revalidates a struct and rejects forged fingerprints or nested batches."
  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_vector_operation}
  def validate(%__MODULE__{kind: :batch} = operation) do
    attrs = %{kind: operation.kind, operations: operation.operations}

    case new(attrs) do
      {:ok, ^operation} -> {:ok, operation}
      _invalid -> invalid()
    end
  end

  def validate(%__MODULE__{} = operation) do
    attrs = %{
      kind: operation.kind,
      record: operation.record,
      expected_generation: operation.expected_generation,
      expected_revision: operation.expected_revision
    }

    case new(attrs) do
      {:ok, ^operation} -> {:ok, operation}
      _invalid -> invalid()
    end
  end

  def validate(_operation), do: invalid()

  @doc "Returns true only for a canonical vector operation."
  @spec valid?(term()) :: boolean()
  def valid?(operation), do: match?({:ok, %__MODULE__{}}, validate(operation))

  @doc "Returns the closed operation-kind set."
  @spec kinds() :: [kind()]
  def kinds, do: [:insert, :update, :delete, :reinsert, :batch]

  @doc "Returns the maximum number of single operations in a batch."
  @spec max_batch_operations() :: pos_integer()
  def max_batch_operations, do: @max_batch_operations

  @doc "Returns batch count and deterministic aggregate transport-byte ceilings."
  @spec limits() :: %{max_batch_operations: pos_integer(), max_batch_bytes: pos_integer()}
  def limits do
    %{max_batch_operations: @max_batch_operations, max_batch_bytes: @max_batch_bytes}
  end

  @doc "Returns all single operations in submission order."
  @spec flatten(t()) :: [t()]
  def flatten(%__MODULE__{kind: :batch, operations: operations}), do: operations
  def flatten(%__MODULE__{} = operation), do: [operation]

  @doc "Returns deterministic transport-byte accounting for one single operation."
  @spec transport_size_bytes(term()) ::
          {:ok, non_neg_integer()} | {:error, :invalid_vector_operation}
  def transport_size_bytes(%__MODULE__{} = operation) do
    with {:ok, operation} <- validate(operation),
         false <- operation.kind == :batch do
      single_transport_size_bytes(operation)
    else
      _invalid -> invalid()
    end
  end

  def transport_size_bytes(_operation), do: invalid()

  @doc "Returns the sole tenant bound by an already validated operation."
  @spec agent_id(t()) :: String.t()
  def agent_id(%__MODULE__{kind: :batch, operations: [first | _]}), do: first.record.agent_id
  def agent_id(%__MODULE__{record: %VectorRecord{} = record}), do: record.agent_id

  defp build_batch_attrs(attrs) do
    case VectorValidation.normalize_attrs(attrs, @attribute_aliases, @batch_fields) do
      {:ok, normalized} -> build_batch(normalized)
      :error -> invalid()
    end
  end

  defp build_single(%{
         kind: kind,
         record: record,
         expected_generation: expected_generation,
         expected_revision: expected_revision
       }) do
    with {:ok, normalized_kind} <- normalize_single_kind(kind),
         {:ok, record} <- VectorRecord.validate(record),
         :ok <- validate_fence(normalized_kind, record, expected_generation, expected_revision) do
      fingerprint =
        single_fingerprint(normalized_kind, record, expected_generation, expected_revision)

      {:ok,
       %__MODULE__{
         kind: normalized_kind,
         record: record,
         expected_generation: expected_generation,
         expected_revision: expected_revision,
         operations: [],
         fingerprint: fingerprint
       }}
    else
      _invalid -> invalid()
    end
  end

  defp build_single(_attrs), do: invalid()

  defp build_batch(%{kind: kind, operations: operations}) do
    with {:ok, :batch} <- normalize_kind(kind),
         {:ok, operations} <- validate_batch_operations(operations) do
      fingerprint =
        VectorValidation.fingerprint([
          "batch",
          Integer.to_string(length(operations))
          | Enum.map(operations, & &1.fingerprint)
        ])

      {:ok,
       %__MODULE__{
         kind: :batch,
         record: nil,
         expected_generation: nil,
         expected_revision: nil,
         operations: operations,
         fingerprint: fingerprint
       }}
    else
      _invalid -> invalid()
    end
  end

  defp build_batch(_attrs), do: invalid()

  defp normalize_single_kind(kind) do
    case normalize_kind(kind) do
      {:ok, normalized} when normalized in [:insert, :update, :delete, :reinsert] ->
        {:ok, normalized}

      _invalid ->
        {:error, :invalid_kind}
    end
  end

  defp normalize_kind(kind), do: Map.fetch(@kind_aliases, kind)

  defp validate_fence(:insert, %VectorRecord{} = record, nil, nil) do
    if record.generation == 0 and record.revision == 0 and not record.tombstone,
      do: :ok,
      else: {:error, :invalid_fence}
  end

  defp validate_fence(kind, %VectorRecord{} = record, generation, revision)
       when kind in [:update, :delete, :reinsert] and is_integer(generation) and generation > 0 and
              is_integer(revision) and revision > 0 do
    if record.generation == generation and record.revision == revision and not record.tombstone and
         fence_can_advance?(kind, generation, revision),
       do: :ok,
       else: {:error, :invalid_fence}
  end

  defp validate_fence(_kind, _record, _generation, _revision),
    do: {:error, :invalid_fence}

  defp validate_batch_operations(operations) when is_list(operations) do
    collect_batch_operations(
      operations,
      [],
      0,
      @batch_fixed_bytes,
      nil,
      MapSet.new()
    )
  end

  defp validate_batch_operations(_operations), do: {:error, :invalid_batch}

  defp collect_batch_operations([], operations, count, _bytes, _agent_id, _identities)
       when count > 0,
       do: {:ok, Enum.reverse(operations)}

  defp collect_batch_operations(
         _remaining,
         _operations,
         @max_batch_operations,
         _bytes,
         _agent_id,
         _identities
       ),
       do: {:error, :invalid_batch}

  defp collect_batch_operations(
         [%__MODULE__{} = operation | rest],
         operations,
         count,
         bytes,
         agent_id,
         identities
       ) do
    with {:ok, operation} <- validate(operation),
         false <- operation.kind == :batch,
         :ok <- same_agent(agent_id, operation.record.agent_id),
         identity <- VectorRecord.identity(operation.record),
         false <- MapSet.member?(identities, identity),
         {:ok, operation_bytes} <- single_transport_size_bytes(operation),
         next_bytes = bytes + 4 + operation_bytes,
         true <- next_bytes <= @max_batch_bytes do
      collect_batch_operations(
        rest,
        [operation | operations],
        count + 1,
        next_bytes,
        agent_id || operation.record.agent_id,
        MapSet.put(identities, identity)
      )
    else
      _invalid -> {:error, :invalid_batch}
    end
  end

  defp collect_batch_operations(
         _improper,
         _operations,
         _count,
         _bytes,
         _agent_id,
         _identities
       ),
       do: {:error, :invalid_batch}

  defp same_agent(nil, _agent_id), do: :ok
  defp same_agent(agent_id, agent_id), do: :ok
  defp same_agent(_expected, _actual), do: {:error, :tenant_mismatch}

  defp fence_can_advance?(kind, generation, revision) when kind in [:update, :delete] do
    generation <= VectorRecord.max_fence_value() and revision < VectorRecord.max_fence_value()
  end

  defp fence_can_advance?(:reinsert, generation, revision) do
    generation < VectorRecord.max_fence_value() and revision <= VectorRecord.max_fence_value()
  end

  defp single_transport_size_bytes(%__MODULE__{} = operation) do
    with {:ok, record_bytes} <- VectorRecord.transport_size_bytes(operation.record) do
      {:ok, @operation_fixed_bytes + byte_size(Atom.to_string(operation.kind)) + record_bytes}
    else
      _invalid -> invalid()
    end
  end

  defp single_fingerprint(kind, record, expected_generation, expected_revision) do
    {agent_id, source_namespace, source_key} = VectorRecord.identity(record)

    VectorValidation.fingerprint([
      Atom.to_string(kind),
      agent_id,
      source_namespace,
      source_key,
      fence_part(expected_generation),
      fence_part(expected_revision),
      record.id,
      record.payload_digest,
      record.vector_digest,
      record.model_id,
      Integer.to_string(record.dimensions),
      Atom.to_string(record.encoding),
      record.category
    ])
  end

  defp fence_part(nil), do: "absent"
  defp fence_part(value), do: Integer.to_string(value)

  defp invalid, do: {:error, :invalid_vector_operation}
end
