defmodule Arbor.Persistence.Schemas.TelemetryEvent do
  @moduledoc """
  Ecto schema for persisted telemetry events.

  Maps to the `telemetry_events` table. Each row is a discrete event
  (turn completed, tool call, routing decision, compaction) that can
  be queried for historical analysis.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  @valid_event_types ~w(turn_completed tool_call routing_decision compaction)

  schema "telemetry_events" do
    field(:agent_id, :string)
    field(:event_type, :string)
    field(:timestamp, :utc_datetime_usec)
    field(:data, :map, default: %{})

    timestamps()
  end

  @required_fields [:id, :agent_id, :event_type, :timestamp]
  @optional_fields [:data]

  @doc """
  Create a changeset for inserting a telemetry event.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:event_type, @valid_event_types)
  end
end
