defmodule Arbor.Persistence.Schemas.SkillRecord do
  @moduledoc """
  Ecto schema for skills in the persistent store.

  Maps to the `skills` table and provides full-text search via
  PostgreSQL tsvector and semantic search via pgvector embeddings.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  # Agent Skills spec: lowercase alphanumeric + hyphens, 1-64 chars
  @name_pattern ~r/\A[a-z0-9][a-z0-9\-]{0,63}\z/

  schema "skills" do
    field :name, :string
    field :description, :string
    field :body, :string, default: ""
    field :tags, {:array, :string}, default: []
    field :category, :string
    field :source, :string, default: "skill"
    field :path, :string
    field :license, :string
    field :compatibility, :string
    field :allowed_tools, {:array, :string}, default: []
    field :content_hash, :string
    field :taint, :string, default: "trusted"
    field :provenance, :map, default: %{}
    field :metadata, :map, default: %{}
    field :embedding, Pgvector.Ecto.Vector

    timestamps()
  end

  @required_fields [:id, :name, :description, :content_hash]
  @optional_fields [
    :body,
    :tags,
    :category,
    :source,
    :path,
    :license,
    :compatibility,
    :allowed_tools,
    :taint,
    :provenance,
    :metadata,
    :embedding
  ]

  @doc """
  Create a changeset for inserting or updating a skill record.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_format(:name, @name_pattern,
      message: "must be lowercase alphanumeric with hyphens, 1-64 chars"
    )
    |> validate_length(:name, min: 1, max: 64)
    |> validate_length(:description, max: 1024)
    |> validate_length(:content_hash, is: 64)
    |> validate_inclusion(:taint, ~w(trusted untrusted))
    |> unique_constraint(:name)
  end
end
