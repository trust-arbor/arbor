defmodule Arbor.Persistence.Schemas.Record do
  @moduledoc """
  Ecto schema for persisted records in the QueryableStore.

  Maps to the `records` table. All domains share this single table,
  differentiated by the `namespace` column (e.g., "jobs", "mailbox", "sessions").

  Provides conversion to/from `Arbor.Contracts.Persistence.Record` structs.

  ## Identity

  - **Logical id** — primary key `id` is the Record's logical id (`rec_…`),
    preserved independently of storage location.
  - **Physical identity** — unique `(namespace, key)`. Lookups and CAS bind to
    those columns, never a concatenated `namespace:key` string.

  ## Fencing

  `generation` and `revision` are backend-maintained and non-negative. Callers
  cannot roll them backward. Soft-delete uses `deleted_at` as a generation
  tombstone so delete/reinsert cannot revive a stale CAS.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Arbor.Contracts.Persistence.Record

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "records" do
    field(:namespace, :string)
    field(:key, :string)
    field(:data, :map, default: %{})
    field(:metadata, :map, default: %{})
    field(:generation, :integer, default: 0)
    field(:revision, :integer, default: 0)
    field(:deleted_at, :utc_datetime_usec)

    timestamps()
  end

  @required_fields [:id, :namespace, :key]
  @optional_fields [:data, :metadata, :generation, :revision, :deleted_at]

  @doc """
  Create a changeset for inserting or updating a record.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:revision, greater_than_or_equal_to: 0)
    |> validate_number(:generation, greater_than_or_equal_to: 0)
    |> unique_constraint(:id, name: "records_pkey")
    |> unique_constraint([:namespace, :key], name: "records_namespace_key_index")
  end

  @doc """
  Convert an `Arbor.Contracts.Persistence.Record` struct to schema attrs map,
  including the namespace for table scoping.
  """
  @spec from_record(Record.t(), String.t()) :: map()
  def from_record(%Record{} = record, namespace) when is_binary(namespace) do
    %{
      id: record.id,
      namespace: namespace,
      key: record.key,
      data: record.data || %{},
      metadata: record.metadata || %{},
      generation: max(record.generation || 0, 0),
      revision: max(record.revision || 0, 0)
    }
  end

  @doc """
  Convert a schema struct back to an `Arbor.Contracts.Persistence.Record`.
  """
  @spec to_record(%__MODULE__{}) :: Record.t()
  def to_record(%__MODULE__{} = schema) do
    %Record{
      id: schema.id,
      key: schema.key,
      data: schema.data || %{},
      metadata: schema.metadata || %{},
      generation: schema.generation || 0,
      revision: schema.revision || 0,
      inserted_at: schema.inserted_at,
      updated_at: schema.updated_at
    }
  end
end
