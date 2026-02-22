defmodule Arbor.Persistence.Schemas.SessionEntry do
  @moduledoc """
  Ecto schema for individual session entries.

  Entries are append-only events within a session: user messages, assistant
  responses, tool calls/results, thinking blocks, heartbeat results, etc.
  The content field stores a structured JSON array matching Claude Code's
  content format (text blocks, tool_use blocks, tool_result blocks, thinking blocks).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Arbor.Persistence.Schemas.Session

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  schema "session_entries" do
    belongs_to :session, Session, type: Ecto.UUID
    belongs_to :parent_entry, __MODULE__, type: Ecto.UUID

    field :entry_type, :string
    field :role, :string
    field :content, {:array, :map}, default: []
    field :model, :string
    field :stop_reason, :string
    field :token_usage, :map
    field :timestamp, :utc_datetime_usec
    field :metadata, :map, default: %{}
  end

  @required_fields [:entry_type, :timestamp]
  @optional_fields [
    :session_id,
    :parent_entry_id,
    :role,
    :content,
    :model,
    :stop_reason,
    :token_usage,
    :metadata
  ]

  @valid_entry_types ~w(user assistant tool_use tool_result thinking system heartbeat progress)
  @valid_roles ~w(user assistant system)

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:entry_type, @valid_entry_types)
    |> validate_inclusion(:role, @valid_roles ++ [nil])
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:parent_entry_id)
  end
end
