defmodule Arbor.Persistence.Schemas.Engagement do
  @moduledoc """
  Ecto schema for engagements — device-independent conversations that channels
  attach to and a Session keys its per-conversation transcript on.

  The durable form of `Arbor.Contracts.Comms.Engagement`. Stored via
  `Arbor.Persistence.Repo`, which is adapter-aware (SQLite3 by default, PostgreSQL
  when configured) — no backend-specific columns. `attached_channels` is a JSON
  array column (`:map`) like `Channel.members`, portable across both adapters.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "engagements" do
    field(:engagement_id, :string)
    field(:agent_id, :string)
    field(:owner_tenant, :string)
    field(:scope, :string, default: "channel")
    field(:status, :string, default: "active")
    field(:visibility, :string, default: "private")
    field(:attached_channels, {:array, :string}, default: [])
    field(:primary_channel, :string)
    field(:metadata, :map, default: %{})

    timestamps()
  end

  @required_fields [:engagement_id, :agent_id]
  @optional_fields [
    :owner_tenant,
    :scope,
    :status,
    :visibility,
    :attached_channels,
    :primary_channel,
    :metadata
  ]

  @valid_scopes ~w(channel user role)
  @valid_statuses ~w(active parked archived)
  @valid_visibilities ~w(private group internal public)

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:scope, @valid_scopes)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:visibility, @valid_visibilities)
    |> unique_constraint(:engagement_id)
  end
end
