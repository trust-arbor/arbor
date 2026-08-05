defmodule Arbor.Contracts.Persistence.VectorRecord do
  @moduledoc """
  Validated transport record for one durable vector row.

  Logical identity is exactly `{agent_id, source_namespace, source_key}`. The
  payload is stored as its normalized JSON representation, while the vector is
  rounded to non-zero-norm IEEE-754 float32 values whose exact big-endian bytes
  determine `vector_digest`. This struct contains no database or Memory
  provenance state.
  """

  use TypedStruct

  alias Arbor.Contracts.Persistence.VectorValidation

  @dimensions 768
  @encoding :ieee754_float32_be_v1
  @max_id_bytes 255
  @max_agent_id_bytes 256
  @max_namespace_bytes 128
  @max_source_key_bytes 1_024
  @max_model_id_bytes 255
  @max_category_bytes 64
  @max_fence_value 9_223_372_036_854_775_807
  @transport_scalar_bytes 65
  @fields [
    :id,
    :agent_id,
    :source_namespace,
    :source_key,
    :payload,
    :vector,
    :payload_digest,
    :vector_digest,
    :model_id,
    :dimensions,
    :encoding,
    :category,
    :generation,
    :revision,
    :tombstone
  ]
  @attribute_aliases Map.new(@fields, fn key -> {key, key} end)
                     |> Map.merge(Map.new(@fields, fn key -> {Atom.to_string(key), key} end))

  @type encoding :: :ieee754_float32_be_v1
  @type identity :: {String.t(), String.t(), String.t()}

  @derive Jason.Encoder
  typedstruct enforce: true do
    @typedoc "A bounded vector row independent of any concrete database adapter"

    field(:id, String.t())
    field(:agent_id, String.t())
    field(:source_namespace, String.t())
    field(:source_key, String.t())
    field(:payload, term())
    field(:vector, [float()])
    field(:payload_digest, String.t())
    field(:vector_digest, String.t())
    field(:model_id, String.t())
    field(:dimensions, pos_integer())
    field(:encoding, encoding())
    field(:category, String.t())
    field(:generation, non_neg_integer())
    field(:revision, non_neg_integer())
    field(:tombstone, boolean())
  end

  @doc "Constructs and fully validates a vector record."
  @spec new(map() | list()) :: {:ok, t()} | {:error, :invalid_vector_record}
  def new(attrs) do
    with {:ok, attrs} <- VectorValidation.normalize_attrs(attrs, @attribute_aliases, @fields),
         true <- VectorValidation.valid_text?(attrs.id, @max_id_bytes),
         {:ok, _identity} <-
           validate_identity(attrs.agent_id, attrs.source_namespace, attrs.source_key),
         true <- VectorValidation.valid_digest?(attrs.payload_digest),
         true <- VectorValidation.valid_digest?(attrs.vector_digest),
         true <- VectorValidation.valid_text?(attrs.model_id, @max_model_id_bytes),
         true <- attrs.dimensions == @dimensions,
         {:ok, encoding} <- normalize_encoding(attrs.encoding),
         true <- VectorValidation.valid_text?(attrs.category, @max_category_bytes),
         true <- valid_fence?(attrs.generation, attrs.revision, attrs.tombstone),
         {:ok, payload, payload_bytes} <- VectorValidation.canonical_payload(attrs.payload),
         true <- VectorValidation.sha256(payload_bytes) == attrs.payload_digest,
         {:ok, vector, vector_bytes} <-
           VectorValidation.normalize_vector(attrs.vector, @dimensions),
         true <- VectorValidation.sha256(vector_bytes) == attrs.vector_digest do
      {:ok,
       %__MODULE__{
         id: attrs.id,
         agent_id: attrs.agent_id,
         source_namespace: attrs.source_namespace,
         source_key: attrs.source_key,
         payload: payload,
         vector: vector,
         payload_digest: attrs.payload_digest,
         vector_digest: attrs.vector_digest,
         model_id: attrs.model_id,
         dimensions: @dimensions,
         encoding: encoding,
         category: attrs.category,
         generation: attrs.generation,
         revision: attrs.revision,
         tombstone: attrs.tombstone
       }}
    else
      _invalid -> {:error, :invalid_vector_record}
    end
  rescue
    _error -> {:error, :invalid_vector_record}
  catch
    _kind, _reason -> {:error, :invalid_vector_record}
  end

  @doc "Revalidates a struct and rejects forged or non-normalized fields."
  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_vector_record}
  def validate(%__MODULE__{} = record) do
    case new(Map.from_struct(record)) do
      {:ok, ^record} -> {:ok, record}
      _invalid -> {:error, :invalid_vector_record}
    end
  end

  def validate(_record), do: {:error, :invalid_vector_record}

  @doc "Returns true only for a canonical vector record."
  @spec valid?(term()) :: boolean()
  def valid?(record), do: match?({:ok, %__MODULE__{}}, validate(record))

  @doc "Returns the fixed physical vector dimensions for this phase."
  @spec dimensions() :: pos_integer()
  def dimensions, do: @dimensions

  @doc "Returns the fixed vector encoding for this phase."
  @spec encoding() :: encoding()
  def encoding, do: @encoding

  @doc "Returns all byte, count, and depth ceilings enforced by this type."
  @spec limits() :: map()
  def limits do
    %{
      id_bytes: @max_id_bytes,
      agent_id_bytes: @max_agent_id_bytes,
      source_namespace_bytes: @max_namespace_bytes,
      source_key_bytes: @max_source_key_bytes,
      model_id_bytes: @max_model_id_bytes,
      category_bytes: @max_category_bytes,
      max_fence_value: @max_fence_value,
      dimensions: @dimensions,
      payload: VectorValidation.payload_limits()
    }
  end

  @doc "Returns the signed BIGINT ceiling for persisted generation and revision fences."
  @spec max_fence_value() :: pos_integer()
  def max_fence_value, do: @max_fence_value

  @doc "Validates and returns an exact logical identity tuple."
  @spec validate_identity(term(), term(), term()) ::
          {:ok, identity()} | {:error, :invalid_vector_identity}
  def validate_identity(agent_id, source_namespace, source_key) do
    if VectorValidation.valid_text?(agent_id, @max_agent_id_bytes) and
         VectorValidation.valid_text?(source_namespace, @max_namespace_bytes) and
         VectorValidation.valid_text?(source_key, @max_source_key_bytes) do
      {:ok, {agent_id, source_namespace, source_key}}
    else
      {:error, :invalid_vector_identity}
    end
  end

  @doc "Returns a record's exact logical identity."
  @spec identity(t()) :: identity()
  def identity(%__MODULE__{} = record) do
    {record.agent_id, record.source_namespace, record.source_key}
  end

  @doc "Validates the exact model, dimensions, encoding, and category descriptor."
  @spec validate_descriptor(term(), term(), term(), term()) ::
          {:ok, {String.t(), pos_integer(), encoding(), String.t()}}
          | {:error, :invalid_vector_descriptor}
  def validate_descriptor(model_id, dimensions, encoding, category) do
    with true <- VectorValidation.valid_text?(model_id, @max_model_id_bytes),
         true <- dimensions == @dimensions,
         {:ok, normalized_encoding} <- normalize_encoding(encoding),
         true <- VectorValidation.valid_text?(category, @max_category_bytes) do
      {:ok, {model_id, @dimensions, normalized_encoding, category}}
    else
      _invalid -> {:error, :invalid_vector_descriptor}
    end
  end

  @doc "Canonicalizes a JSON-shaped payload and returns its exact encoded bytes."
  @spec canonical_payload_bytes(term()) :: {:ok, binary()} | {:error, atom()}
  def canonical_payload_bytes(payload) do
    case VectorValidation.canonical_payload(payload) do
      {:ok, _normalized, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Computes the lowercase SHA-256 digest of a canonical payload."
  @spec payload_digest(term()) :: {:ok, String.t()} | {:error, atom()}
  def payload_digest(payload) do
    with {:ok, bytes} <- canonical_payload_bytes(payload) do
      {:ok, VectorValidation.sha256(bytes)}
    end
  end

  @doc "Rounds a vector to exact finite float32 values and rejects zero norm."
  @spec normalize_vector(term()) :: {:ok, [float()]} | {:error, :invalid_vector}
  def normalize_vector(vector) do
    case VectorValidation.normalize_vector(vector, @dimensions) do
      {:ok, normalized, _bytes} -> {:ok, normalized}
      {:error, :invalid_vector} = error -> error
    end
  end

  @doc "Returns the deterministic big-endian bytes for a normalized vector."
  @spec vector_bytes(term()) :: {:ok, binary()} | {:error, :invalid_vector}
  def vector_bytes(vector) do
    case VectorValidation.normalize_vector(vector, @dimensions) do
      {:ok, _normalized, bytes} -> {:ok, bytes}
      {:error, :invalid_vector} = error -> error
    end
  end

  @doc "Computes the lowercase SHA-256 digest of normalized float32 bytes."
  @spec vector_digest(term()) :: {:ok, String.t()} | {:error, :invalid_vector}
  def vector_digest(vector) do
    with {:ok, bytes} <- vector_bytes(vector) do
      {:ok, VectorValidation.sha256(bytes)}
    end
  end

  @doc "Returns deterministic canonical transport-byte accounting for a record."
  @spec transport_size_bytes(term()) ::
          {:ok, non_neg_integer()} | {:error, :invalid_vector_record}
  def transport_size_bytes(%__MODULE__{} = record) do
    with {:ok, record} <- validate(record),
         {:ok, payload_bytes} <- canonical_payload_bytes(record.payload),
         {:ok, vector_bytes} <- vector_bytes(record.vector) do
      variable_bytes =
        [
          record.id,
          record.agent_id,
          record.source_namespace,
          record.source_key,
          payload_bytes,
          vector_bytes,
          record.payload_digest,
          record.vector_digest,
          record.model_id,
          Atom.to_string(record.encoding),
          record.category
        ]
        |> Enum.reduce(0, fn value, total -> total + byte_size(value) end)

      {:ok, @transport_scalar_bytes + variable_bytes}
    else
      _invalid -> {:error, :invalid_vector_record}
    end
  end

  def transport_size_bytes(_record), do: {:error, :invalid_vector_record}

  @doc "Compares every field except backend-advanced fence and tombstone state."
  @spec same_value?(t(), t()) :: boolean()
  def same_value?(%__MODULE__{} = left, %__MODULE__{} = right) do
    Map.drop(Map.from_struct(left), [:generation, :revision, :tombstone]) ==
      Map.drop(Map.from_struct(right), [:generation, :revision, :tombstone])
  end

  defp normalize_encoding(@encoding), do: {:ok, @encoding}
  defp normalize_encoding("ieee754_float32_be_v1"), do: {:ok, @encoding}
  defp normalize_encoding(_encoding), do: {:error, :invalid_encoding}

  defp valid_fence?(generation, revision, tombstone) do
    is_integer(generation) and generation >= 0 and generation <= @max_fence_value and
      is_integer(revision) and revision >= 0 and revision <= @max_fence_value and
      is_boolean(tombstone)
  end
end
