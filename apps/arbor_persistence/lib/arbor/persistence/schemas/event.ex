defmodule Arbor.Persistence.Schemas.Event do
  @moduledoc """
  Ecto schema for persisted events.

  Maps to the `events` table and provides conversion to/from
  `Arbor.Persistence.Event` structs.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Arbor.Persistence.Event

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "events" do
    field :stream_id, :string
    field :event_number, :integer
    field :global_position, :integer
    field :type, :string
    field :data, :map, default: %{}
    field :metadata, :map, default: %{}
    field :causation_id, :string
    field :correlation_id, :string
    field :event_timestamp, :utc_datetime_usec

    timestamps(inserted_at: :created_at, updated_at: false)
  end

  @required_fields [:id, :stream_id, :event_number, :type]
  @optional_fields [:global_position, :data, :metadata, :causation_id, :correlation_id, :event_timestamp]

  @doc """
  Create a changeset for inserting a new event.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end

  @doc """
  Convert an Arbor.Persistence.Event struct to schema attrs.
  """
  @spec from_event(Event.t()) :: map()
  def from_event(%Event{} = event) do
    %{
      id: event.id,
      stream_id: event.stream_id,
      event_number: event.event_number,
      global_position: event.global_position,
      type: event.type,
      data: event.data || %{},
      metadata: event.metadata || %{},
      causation_id: event.causation_id,
      correlation_id: event.correlation_id,
      event_timestamp: event.timestamp
    }
  end

  @doc """
  Convert a schema struct to an Arbor.Persistence.Event.
  """
  @spec to_event(%__MODULE__{}) :: Event.t()
  def to_event(%__MODULE__{} = schema) do
    %Event{
      id: schema.id,
      stream_id: schema.stream_id,
      event_number: schema.event_number,
      global_position: schema.global_position,
      type: schema.type,
      data: schema.data || %{},
      metadata: schema.metadata || %{},
      causation_id: schema.causation_id,
      correlation_id: schema.correlation_id,
      timestamp: schema.event_timestamp
    }
  end
end
