defmodule Arbor.Contracts.Events.Event do
  @moduledoc """
  Core event structure for event sourcing in the Arbor system.

  Events are immutable facts that represent state changes in the system.
  They form the foundation of our event sourcing architecture, providing
  a complete audit trail and enabling state reconstruction.

  ## Event Design Principles

  - **Immutable**: Events are never modified after creation
  - **Self-contained**: Events contain all data needed to apply them
  - **Versioned**: Events include schema version for evolution
  - **Traceable**: Full correlation IDs for distributed tracing

  ## Event Types

  Events are organized by domain:
  - `agent.*` - Agent lifecycle and state changes
  - `security.*` - Capability grants, revocations, violations
  - `session.*` - Session management events
  - `system.*` - System-level events (cluster, node changes)

  ## Usage

      event = Event.new(
        type: :agent_started,
        aggregate_id: "agent_123",
        data: %{
          agent_type: :llm,
          capabilities: ["read", "write"]
        },
        causation_id: "cmd_start_agent_xyz",
        correlation_id: "session_abc",
        metadata: %{user_id: "user_123"}
      )

  @version "1.0.0"
  """

  use TypedStruct

  alias Arbor.Types

  @derive Jason.Encoder
  typedstruct enforce: true do
    @typedoc "An immutable event representing a state change"

    # Event identification
    field(:id, String.t())
    field(:type, atom())
    field(:version, String.t(), default: "1.0.0")

    # Event data
    field(:aggregate_id, String.t())
    field(:aggregate_type, atom())
    field(:data, map())
    field(:timestamp, DateTime.t())

    # Correlation for distributed tracing
    field(:causation_id, String.t(), enforce: false)
    field(:correlation_id, String.t(), enforce: false)
    field(:trace_id, Types.trace_id(), enforce: false)

    # Stream positioning
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
  - `:aggregate_id` - ID of the aggregate this event belongs to
  - `:data` - Event payload data

  ## Optional Fields

  - `:aggregate_type` - Type of aggregate (defaults from aggregate_id prefix)
  - `:version` - Event schema version
  - `:causation_id` - ID of the command/event that caused this event
  - `:correlation_id` - ID for correlating related events
  - `:trace_id` - Distributed trace ID
  - `:metadata` - Additional context

  ## Examples

      # Basic event
      {:ok, event} = Event.new(
        type: :capability_granted,
        aggregate_id: "agent_123",
        data: %{
          capability_id: "cap_456",
          resource_uri: "arbor://fs/read/docs"
        }
      )

      # Event with full tracing
      {:ok, event} = Event.new(
        type: :task_completed,
        aggregate_id: "agent_worker_789",
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
      aggregate_id: Keyword.fetch!(attrs, :aggregate_id),
      aggregate_type: attrs[:aggregate_type] || infer_aggregate_type(attrs[:aggregate_id]),
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
  Apply an event to a state, returning the new state.

  This is used during event replay to reconstruct state from events.
  The actual application logic is domain-specific and should be
  implemented by the aggregate.

  ## Example

      defmodule AgentAggregate do
        def apply_event(%Event{type: :agent_started} = event, nil) do
          %{
            id: event.aggregate_id,
            status: :active,
            started_at: event.timestamp,
            capabilities: event.data.capabilities
          }
        end

        def apply_event(%Event{type: :capability_granted} = event, state) do
          %{state | capabilities: [event.data.capability | state.capabilities]}
        end
      end
  """
  @spec apply_event(t(), state :: any()) :: any()
  def apply_event(%__MODULE__{} = event, state) do
    # Delegate to domain-specific application logic
    apply_module =
      Module.concat([
        "Arbor.Core.Aggregates",
        Macro.camelize(to_string(event.aggregate_type)),
        "Aggregate"
      ])

    if Code.ensure_loaded?(apply_module) and
         function_exported?(apply_module, :apply_event, 2) do
      apply_module.apply_event(event, state)
    else
      raise "No aggregate module found for type: #{event.aggregate_type}"
    end
  end

  @doc """
  Set stream positioning information on an event.

  Called by the event store when appending events to set their
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
      aggregate_id: get_field(map, :aggregate_id),
      aggregate_type: atomize_safely(get_field(map, :aggregate_type)),
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

  defp infer_aggregate_type(aggregate_id) when is_binary(aggregate_id) do
    case String.split(aggregate_id, "_", parts: 2) do
      [prefix, _] -> String.to_atom(prefix)
      _ -> :unknown
    end
  end

  defp infer_aggregate_type(_), do: :unknown

  defp validate_event(%__MODULE__{} = event) do
    validators = [
      &validate_type/1,
      &validate_aggregate_id/1,
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

  defp validate_aggregate_id(%{aggregate_id: id}) when is_binary(id) and byte_size(id) > 0,
    do: :ok

  defp validate_aggregate_id(%{aggregate_id: id}), do: {:error, {:invalid_aggregate_id, id}}

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
    String.to_existing_atom(string)
  rescue
    ArgumentError -> String.to_atom(string)
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
