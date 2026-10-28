defmodule Arbor.Persistence.Schemas.Session do
  @moduledoc """
  Ecto schema for agent sessions.

  A session is an agent's private, append-only life log. It tracks the
  session lifecycle (active/paused/terminated) and contains references
  to all session entries (turns, heartbeats, tool calls, etc.).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Arbor.Persistence.Schemas.SessionEntry

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "sessions" do
    field :session_id, :string
    field :agent_id, :string
    field :status, :string, default: "active"
    field :model, :string
    field :cwd, :string
    field :git_branch, :string
    field :metadata, :map, default: %{}

    has_many :entries, SessionEntry, foreign_key: :session_id

    timestamps()
  end

  @required_fields [:session_id, :agent_id]
  @optional_fields [:status, :model, :cwd, :git_branch, :metadata]

  @valid_statuses ~w(active paused terminated)

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:session_id)
  end
end
