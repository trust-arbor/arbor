defmodule Arbor.Persistence.Event do
  @moduledoc """
  An immutable event for the EventLog.

  Events are append-only entries in a stream, identified by stream_id
  and ordered by event_number within the stream. Global ordering is
  tracked via global_position.

  Supports causation and correlation IDs for distributed tracing.
  """

  use TypedStruct

  typedstruct do
    @typedoc "An immutable event log entry"

    field :id, String.t(), enforce: true
    field :stream_id, String.t(), enforce: true
    field :event_number, non_neg_integer(), enforce: true
    field :global_position, non_neg_integer()
    field :type, String.t(), enforce: true
    field :data, map(), default: %{}
    field :metadata, map(), default: %{}
    field :causation_id, String.t()
    field :correlation_id, String.t()
    field :timestamp, DateTime.t()
  end

  @doc """
  Create a new event. The event_number and global_position are typically
  assigned by the EventLog adapter, not the caller.
  """
  @spec new(String.t(), String.t(), map(), keyword()) :: t()
  def new(stream_id, type, data \\ %{}, opts \\ []) do
    %__MODULE__{
      id: Keyword.get(opts, :id, Arbor.Identifiers.generate_id("evt_")),
      stream_id: stream_id,
      event_number: Keyword.get(opts, :event_number, 0),
      global_position: Keyword.get(opts, :global_position),
      type: type,
      data: data,
      metadata: Keyword.get(opts, :metadata, %{}),
      causation_id: Keyword.get(opts, :causation_id),
      correlation_id: Keyword.get(opts, :correlation_id),
      timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now())
    }
  end

  defimpl Jason.Encoder do
    def encode(event, opts) do
      event
      |> Map.from_struct()
      |> Map.update(:timestamp, nil, &to_string/1)
      |> Jason.Encode.map(opts)
    end
  end
end
