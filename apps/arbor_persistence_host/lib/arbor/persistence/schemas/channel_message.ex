defmodule Arbor.Persistence.Schemas.ChannelMessage do
  @moduledoc """
  Ecto schema for messages within a channel.

  Each message has a sender identity (id, name, type) and a text content field.
  Metadata can hold reactions, edits, attachments, or other extensible data.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Arbor.Persistence.Schemas.Channel

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  schema "channel_messages" do
    belongs_to :channel, Channel, type: Ecto.UUID

    field :sender_id, :string
    field :sender_name, :string
    field :sender_type, :string, default: "human"
    field :content, :string
    field :timestamp, :utc_datetime_usec
    field :metadata, :map, default: %{}
  end

  @required_fields [:sender_id, :content, :timestamp]
  @optional_fields [:channel_id, :sender_name, :sender_type, :metadata]

  @valid_sender_types ~w(human agent system)

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:sender_type, @valid_sender_types)
    |> foreign_key_constraint(:channel_id)
  end
end
