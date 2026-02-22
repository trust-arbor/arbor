defmodule Arbor.Persistence.Schemas.Channel do
  @moduledoc """
  Ecto schema for communication channels.

  A channel is a shared message container with sender identity tracking.
  Types include DMs (agent-specific chat), group chats, public channels,
  and ops rooms. Members are stored as a JSONB array of member maps.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Arbor.Persistence.Schemas.ChannelMessage

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "channels" do
    field :channel_id, :string
    field :type, :string, default: "dm"
    field :name, :string
    field :owner_id, :string
    field :members, {:array, :map}, default: []
    field :metadata, :map, default: %{}

    has_many :messages, ChannelMessage, foreign_key: :channel_id

    timestamps()
  end

  @required_fields [:channel_id]
  @optional_fields [:type, :name, :owner_id, :members, :metadata]

  @valid_types ~w(dm group public ops_room)

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:type, @valid_types)
    |> unique_constraint(:channel_id)
  end
end
