defmodule Arbor.Persistence.Record do
  @moduledoc """
  A structured record for the QueryableStore.

  Records wrap key-value data with metadata, timestamps, and a unique ID
  for queryable storage backends.
  """

  use TypedStruct

  typedstruct do
    @typedoc "A persistence record with metadata and timestamps"

    field :id, String.t(), enforce: true
    field :key, String.t(), enforce: true
    field :data, map(), default: %{}
    field :metadata, map(), default: %{}
    field :inserted_at, DateTime.t()
    field :updated_at, DateTime.t()
  end

  @doc """
  Create a new record with auto-generated ID and timestamps.
  """
  @spec new(String.t(), map(), keyword()) :: t()
  def new(key, data \\ %{}, opts \\ []) do
    now = DateTime.utc_now()

    %__MODULE__{
      id: Keyword.get(opts, :id, Arbor.Identifiers.generate_id("rec_")),
      key: key,
      data: data,
      metadata: Keyword.get(opts, :metadata, %{}),
      inserted_at: Keyword.get(opts, :inserted_at, now),
      updated_at: Keyword.get(opts, :updated_at, now)
    }
  end

  @doc """
  Update a record's data and bump updated_at.
  """
  @spec update(t(), map(), keyword()) :: t()
  def update(%__MODULE__{} = record, data, opts \\ []) do
    %{record |
      data: data,
      metadata: Keyword.get(opts, :metadata, record.metadata),
      updated_at: DateTime.utc_now()
    }
  end

  defimpl Jason.Encoder do
    def encode(record, opts) do
      record
      |> Map.from_struct()
      |> Map.update(:inserted_at, nil, &to_string/1)
      |> Map.update(:updated_at, nil, &to_string/1)
      |> Jason.Encode.map(opts)
    end
  end
end
