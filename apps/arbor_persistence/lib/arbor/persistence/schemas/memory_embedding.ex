defmodule Arbor.Persistence.Schemas.MemoryEmbedding do
  @moduledoc """
  Ecto schema for memory embeddings.

  Maps to the `memory_embeddings` table and provides persistent vector storage
  for semantic memory retrieval using pgvector.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "memory_embeddings" do
    field :agent_id, :string
    field :content, :string
    field :content_hash, :string
    field :embedding, Pgvector.Ecto.Vector
    field :memory_type, :string
    field :source, :string
    field :metadata, :map, default: %{}

    timestamps()
  end

  @required_fields [:id, :agent_id, :content, :content_hash, :embedding]
  @optional_fields [:memory_type, :source, :metadata]

  @doc """
  Create a changeset for inserting or updating a memory embedding.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:content_hash, is: 64)
    |> validate_length(:memory_type, max: 50)
    |> validate_length(:source, max: 255)
  end
end
