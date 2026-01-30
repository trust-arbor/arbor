defmodule Arbor.Persistence.Schemas.Record do
  @moduledoc """
  Ecto schema for persisted records in the QueryableStore.

  Maps to the `records` table. All domains share this single table,
  differentiated by the `namespace` column (e.g., "jobs", "mailbox", "sessions").

  Provides conversion to/from `Arbor.Persistence.Record` structs.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Arbor.Persistence.Record

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "records" do
    field :namespace, :string
    field :key, :string
    field :data, :map, default: %{}
    field :metadata, :map, default: %{}

    timestamps()
  end

  @required_fields [:id, :namespace, :key]
  @optional_fields [:data, :metadata]

  @doc """
  Create a changeset for inserting or updating a record.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint([:namespace, :key])
  end

  @doc """
  Convert an `Arbor.Persistence.Record` struct to schema attrs map,
  including the namespace for table scoping.
  """
  @spec from_record(Record.t(), String.t()) :: map()
  def from_record(%Record{} = record, namespace) when is_binary(namespace) do
    %{
      id: record.id,
      namespace: namespace,
      key: record.key,
      data: record.data || %{},
      metadata: record.metadata || %{}
    }
  end

  @doc """
  Convert a schema struct back to an `Arbor.Persistence.Record`.
  """
  @spec to_record(%__MODULE__{}) :: Record.t()
  def to_record(%__MODULE__{} = schema) do
    %Record{
      id: schema.id,
      key: schema.key,
      data: schema.data || %{},
      metadata: schema.metadata || %{},
      inserted_at: schema.inserted_at,
      updated_at: schema.updated_at
    }
  end
end
