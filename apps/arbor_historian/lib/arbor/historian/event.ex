defmodule Arbor.Historian.Event do
  @moduledoc """
  Domain event structure for the Arbor historian.

  Uses `Arbor.Common.SafeAtom` for safe string-to-atom conversion to prevent
  atom exhaustion attacks from untrusted input.

  Events are immutable facts that represent state changes in the system.
  They are the historian's primary data type — signals are transformed into
  events for durable storage, and events are enriched into history entries
  for querying.

  ## Event Design Principles

  - **Immutable**: Events are never modified after creation
  - **Self-contained**: Events contain all data needed to understand what happened
  - **Versioned**: Events include schema version for evolution
  - **Traceable**: Full correlation IDs for distributed tracing

  ## Event Types

  Events are organized by domain:
  - `activity.*` - Agent lifecycle and state changes
  - `security.*` - Capability grants, revocations, violations
  - `session.*` - Session management events
  - `system.*` - System-level events (cluster, node changes)

  ## Usage

      event = Event.new(
        type: :agent_started,
        subject_id: "agent_123",
        data: %{
          agent_type: :llm,
          capabilities: ["read", "write"]
        },
        causation_id: "cmd_start_agent_xyz",
        correlation_id: "session_abc",
        metadata: %{user_id: "user_123"}
      )

  ## Stream Positioning

  Events gain stream positioning (`stream_id`, `stream_version`, `global_position`)
  when stored via an EventLog backend. These fields are nil on creation and set
  by the storage layer via `set_position/4`.

  @version "1.0.0"
  """

  use TypedStruct

  alias Arbor.Common.SafeAtom

  @derive Jason.Encoder
  typedstruct enforce: true do
    @typedoc "An immutable event representing a state change"

    # Event identification
    field(:id, String.t())
    field(:type, atom())
    field(:version, String.t(), default: "1.0.0")

    # What this event is about
    field(:subject_id, String.t())
    field(:subject_type, atom())

    # Event data
    field(:data, map())
    field(:timestamp, DateTime.t())

    # Correlation for distributed tracing
    field(:causation_id, String.t(), enforce: false)
    field(:correlation_id, String.t(), enforce: false)
    field(:trace_id, String.t(), enforce: false)

    # Stream positioning (set by EventLog backends on storage)
    field(:stream_id, String.t(), enforce: false)
    field(:stream_version, non_neg_integer(), enforce: false)
    field(:global_position, non_neg_integer(), enforce: false)

    # Additional context
    field(:metadata, map(), default: %{})
  end

  @doc """
  Create a new event with validation.

  ## Required Fields

  - `:type` - Event type atom (e.g., :agent_started)
  - `:subject_id` - ID of the entity this event is about
  - `:data` - Event payload data

  ## Optional Fields

  - `:subject_type` - Type of subject (defaults from subject_id prefix)
  - `:version` - Event schema version
  - `:causation_id` - ID of the command/event that caused this event
  - `:correlation_id` - ID for correlating related events
  - `:trace_id` - Distributed trace ID
  - `:metadata` - Additional context

  ## Examples

      # Basic event
      {:ok, event} = Event.new(
        type: :capability_granted,
        subject_id: "agent_123",
        data: %{
          capability_id: "cap_456",
          resource_uri: "arbor://fs/read/docs"
        }
      )

      # Event with full tracing
      {:ok, event} = Event.new(
        type: :task_completed,
        subject_id: "agent_worker_789",
        data: %{task_id: "task_123", result: "success"},
        causation_id: "msg_process_task_456",
        correlation_id: "session_abc",
        trace_id: "trace_xyz"
      )
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    event = %__MODULE__{
      id: attrs[:id] || generate_event_id(),
      type: Keyword.fetch!(attrs, :type),
      version: attrs[:version] || "1.0.0",
      subject_id: Keyword.fetch!(attrs, :subject_id),
      subject_type: attrs[:subject_type] || infer_subject_type(attrs[:subject_id]),
      data: Keyword.fetch!(attrs, :data),
      timestamp: attrs[:timestamp] || DateTime.utc_now(),
      causation_id: attrs[:causation_id],
      correlation_id: attrs[:correlation_id],
      trace_id: attrs[:trace_id],
      stream_id: attrs[:stream_id],
      stream_version: attrs[:stream_version],
      global_position: attrs[:global_position],
      metadata: attrs[:metadata] || %{}
    }

    case validate_event(event) do
      :ok -> {:ok, event}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Set stream positioning information on an event.

  Called by EventLog backends when appending events to set their
  position in the stream and globally.
  """
  @spec set_position(t(), String.t(), non_neg_integer(), non_neg_integer()) :: t()
  def set_position(%__MODULE__{} = event, stream_id, stream_version, global_position) do
    %{
      event
      | stream_id: stream_id,
        stream_version: stream_version,
        global_position: global_position
    }
  end

  @doc """
  Convert event to a map suitable for serialization.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = event) do
    Map.from_struct(event)
  end

  @doc """
  Restore an event from a serialized map.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(map) when is_map(map) do
    attrs = parse_map_fields(map)
    new(attrs)
  end

  defp parse_map_fields(map) do
    [
      id: get_field(map, :id),
      type: atomize_safely(get_field(map, :type)),
      version: get_field(map, :version),
      subject_id: get_field(map, :subject_id),
      subject_type: atomize_safely(get_field(map, :subject_type)),
      data: get_field(map, :data),
      timestamp: parse_timestamp(get_field(map, :timestamp)),
      causation_id: get_field(map, :causation_id),
      correlation_id: get_field(map, :correlation_id),
      trace_id: get_field(map, :trace_id),
      stream_id: get_field(map, :stream_id),
      stream_version: get_field(map, :stream_version),
      global_position: get_field(map, :global_position),
      metadata: get_field(map, :metadata) || %{}
    ]
  end

  defp get_field(map, key) do
    map[Atom.to_string(key)] || map[key]
  end

  # Private functions

  defp generate_event_id do
    "event_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  defp infer_subject_type(subject_id) when is_binary(subject_id) do
    SafeAtom.infer_subject_type(subject_id)
  end

  defp infer_subject_type(_), do: :unknown

  defp validate_event(%__MODULE__{} = event) do
    validators = [
      &validate_type/1,
      &validate_subject_id/1,
      &validate_data/1,
      &validate_version/1
    ]

    Enum.reduce_while(validators, :ok, fn validator, :ok ->
      case validator.(event) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_type(%{type: type}) when is_atom(type) and type != nil, do: :ok
  defp validate_type(%{type: type}), do: {:error, {:invalid_event_type, type}}

  defp validate_subject_id(%{subject_id: id}) when is_binary(id) and byte_size(id) > 0,
    do: :ok

  defp validate_subject_id(%{subject_id: id}), do: {:error, {:invalid_subject_id, id}}

  defp validate_data(%{data: data}) when is_map(data), do: :ok
  defp validate_data(%{data: data}), do: {:error, {:invalid_event_data, data}}

  defp validate_version(%{version: version}) when is_binary(version) do
    if Regex.match?(~r/^\d+\.\d+\.\d+$/, version) do
      :ok
    else
      {:error, {:invalid_version_format, version}}
    end
  end

  defp validate_version(%{version: version}), do: {:error, {:invalid_version, version}}

  defp atomize_safely(nil), do: nil
  defp atomize_safely(atom) when is_atom(atom), do: atom

  defp atomize_safely(string) when is_binary(string) do
    case SafeAtom.to_existing(string) do
      {:ok, atom} -> atom
      # If the string doesn't exist as an atom, return :unknown to prevent DoS
      {:error, _} -> :unknown
    end
  end

  defp parse_timestamp(%DateTime{} = dt), do: dt

  defp parse_timestamp(string) when is_binary(string) do
    case DateTime.from_iso8601(string) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_timestamp(_), do: DateTime.utc_now()
end
