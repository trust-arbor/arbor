defmodule Arbor.Contracts.Persistence.VectorMatch do
  @moduledoc """
  Validated similarity-search result.

  The complete `VectorRecord` is retained so callers can verify payload and
  vector digests before admitting a search result. Tombstones are never valid
  matches.
  """

  use TypedStruct

  alias Arbor.Contracts.Persistence.{VectorRecord, VectorValidation}

  @fields [:record, :similarity]
  @attribute_aliases Map.new(@fields, fn key -> {key, key} end)
                     |> Map.merge(Map.new(@fields, fn key -> {Atom.to_string(key), key} end))

  @derive Jason.Encoder
  typedstruct enforce: true do
    @typedoc "A digest-verifiable vector row and finite cosine similarity"

    field(:record, VectorRecord.t())
    field(:similarity, float())
  end

  @doc "Constructs a match with a normalized finite float32 similarity."
  @spec new(map() | list()) :: {:ok, t()} | {:error, :invalid_vector_match}
  def new(attrs) do
    with {:ok, attrs} <- VectorValidation.normalize_attrs(attrs, @attribute_aliases, @fields),
         {:ok, record} <- VectorRecord.validate(attrs.record),
         false <- record.tombstone,
         {:ok, similarity, _bytes} <- VectorValidation.normalize_float32(attrs.similarity),
         true <- similarity >= -1.0 and similarity <= 1.0 do
      {:ok, %__MODULE__{record: record, similarity: similarity}}
    else
      _invalid -> {:error, :invalid_vector_match}
    end
  rescue
    _error -> {:error, :invalid_vector_match}
  catch
    _kind, _reason -> {:error, :invalid_vector_match}
  end

  @doc "Revalidates a struct and rejects forged or non-normalized fields."
  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_vector_match}
  def validate(%__MODULE__{} = match) do
    case new(Map.from_struct(match)) do
      {:ok, ^match} -> {:ok, match}
      _invalid -> {:error, :invalid_vector_match}
    end
  end

  def validate(_match), do: {:error, :invalid_vector_match}

  @doc "Returns true only for a canonical vector match."
  @spec valid?(term()) :: boolean()
  def valid?(match), do: match?({:ok, %__MODULE__{}}, validate(match))
end
