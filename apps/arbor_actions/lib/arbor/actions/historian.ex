defmodule Arbor.Actions.Historian do
  @moduledoc """
  Historian query operations as Jido actions.

  This module provides Jido-compatible actions for querying the event log,
  tracing causality chains, and reconstructing historical state. Actions
  wrap the `Arbor.Historian` facade and provide proper observability.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `QueryEvents` | Query the event log with filters |
  | `CausalityTree` | Build a causal chain from an event |
  | `ReconstructState` | Reconstruct system state at a point in time |

  ## Examples

      # Query recent events
      {:ok, result} = Arbor.Actions.Historian.QueryEvents.run(
        %{category: "agent", limit: 50},
        %{}
      )
      result.events  # => [%{...}, ...]

      # Trace causality
      {:ok, result} = Arbor.Actions.Historian.CausalityTree.run(
        %{event_id: "evt_123"},
        %{}
      )
      result.tree  # => nested cause/effect structure

  ## Authorization

  Capability URIs follow the pattern `arbor://actions/execute/historian.query_events`.
  Sensitive categories like `:security` may require additional capabilities.
  """

  defmodule QueryEvents do
    @moduledoc """
    Query the event log through an action.

    Wraps `Arbor.Historian.query/1` as a Jido action for consistent
    execution and LLM tool schema generation.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `stream` | string | no | Stream ID to query |
    | `category` | string | no | Event category filter (e.g., "agent", "security") |
    | `type` | string | no | Event type filter |
    | `source` | string | no | Event source filter |
    | `from` | string | no | Start time (ISO8601) |
    | `to` | string | no | End time (ISO8601) |
    | `limit` | integer | no | Maximum events to return (default: 100) |

    ## Returns

    - `events` - List of matching events
    - `count` - Number of events returned
    """

    use Jido.Action,
      name: "historian_query_events",
      description: "Query the event log with optional filters",
      category: "historian",
      tags: ["historian", "events", "query", "audit"],
      schema: [
        stream: [
          type: :string,
          doc: "Stream ID to query"
        ],
        category: [
          type: :string,
          doc: "Event category filter (e.g., 'agent', 'security', 'shell')"
        ],
        type: [
          type: :string,
          doc: "Event type filter"
        ],
        source: [
          type: :string,
          doc: "Event source filter"
        ],
        from: [
          type: :string,
          doc: "Start time in ISO8601 format"
        ],
        to: [
          type: :string,
          doc: "End time in ISO8601 format"
        ],
        limit: [
          type: :integer,
          default: 100,
          doc: "Maximum number of events to return"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Common.SafeAtom

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(params, _context) do
      Actions.emit_started(__MODULE__, sanitize_params(params))

      opts = build_opts(params)

      case Arbor.Historian.query(opts) do
        {:ok, events} ->
          result = %{
            events: events,
            count: length(events)
          }

          Actions.emit_completed(__MODULE__, %{count: length(events)})
          {:ok, result}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, format_error(reason)}
      end
    end

    defp build_opts(params) do
      []
      |> maybe_add(:stream, params[:stream])
      |> maybe_add(:category, maybe_to_atom(params[:category]))
      |> maybe_add(:type, maybe_to_atom(params[:type]))
      |> maybe_add(:source, params[:source])
      |> maybe_add(:from, parse_datetime(params[:from]))
      |> maybe_add(:to, parse_datetime(params[:to]))
      |> maybe_add(:limit, params[:limit])
    end

    defp maybe_add(opts, _key, nil), do: opts
    defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

    defp maybe_to_atom(nil), do: nil

    defp maybe_to_atom(str) when is_binary(str) do
      case SafeAtom.to_existing(str) do
        {:ok, atom} -> atom
        {:error, _} -> nil
      end
    end

    defp maybe_to_atom(atom) when is_atom(atom), do: atom

    defp parse_datetime(nil), do: nil

    defp parse_datetime(str) when is_binary(str) do
      case DateTime.from_iso8601(str) do
        {:ok, dt, _offset} -> dt
        _ -> nil
      end
    end

    defp parse_datetime(%DateTime{} = dt), do: dt

    defp sanitize_params(params) do
      Map.take(params, [:category, :type, :limit])
    end

    defp format_error({:unauthorized, reason}), do: "Unauthorized: #{inspect(reason)}"
    defp format_error(reason), do: "Query failed: #{inspect(reason)}"
  end

  defmodule CausalityTree do
    @moduledoc """
    Build a causal chain from an event backward.

    Traces cause-effect chains through correlation IDs to help with
    root cause analysis and debugging.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `event_id` | string | yes | The event ID to trace from |
    | `max_depth` | integer | no | Maximum chain depth (default: 10) |

    ## Returns

    - `root_event` - The starting event
    - `chain` - List of causally-related events (newest first)
    - `depth` - Actual depth of the chain
    """

    use Jido.Action,
      name: "historian_causality_tree",
      description: "Build a causal chain from an event for root cause analysis",
      category: "historian",
      tags: ["historian", "causality", "debug", "trace"],
      schema: [
        event_id: [
          type: :string,
          required: true,
          doc: "The event ID (signal ID) to trace from"
        ],
        max_depth: [
          type: :integer,
          default: 10,
          doc: "Maximum depth to trace (default: 10)"
        ]
      ]

    alias Arbor.Actions

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(%{event_id: event_id} = params, _context) do
      max_depth = params[:max_depth] || 10

      Actions.emit_started(__MODULE__, %{event_id: event_id, max_depth: max_depth})

      # Use causality_chain from Historian.Timeline
      opts = [max_depth: max_depth]

      case Arbor.Historian.causality_chain(event_id, opts) do
        {:ok, []} ->
          # No chain found - event exists but has no causal relationships
          result = %{
            root_event: nil,
            chain: [],
            depth: 0
          }

          Actions.emit_completed(__MODULE__, %{depth: 0})
          {:ok, result}

        {:ok, chain} when is_list(chain) ->
          result = %{
            root_event: List.last(chain),
            chain: chain,
            depth: length(chain)
          }

          Actions.emit_completed(__MODULE__, %{depth: result.depth})
          {:ok, result}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, format_error(reason)}
      end
    end

    defp format_error(:not_found), do: "Event not found"
    defp format_error({:unauthorized, reason}), do: "Unauthorized: #{inspect(reason)}"
    defp format_error(reason), do: "Causality trace failed: #{inspect(reason)}"
  end

  defmodule ReconstructState do
    @moduledoc """
    Reconstruct system state at a point in time.

    Uses event sourcing replay to reconstruct what the system state
    looked like at a specific timestamp. Useful for debugging and
    understanding "what did the system look like when this failed?"

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `stream` | string | yes | Stream to reconstruct (e.g., "agent:agent_001") |
    | `as_of` | string | yes | Timestamp to reconstruct to (ISO8601) |
    | `include_events` | boolean | no | Include the events in the response (default: false) |

    ## Returns

    - `state` - Reconstructed state map
    - `event_count` - Number of events processed
    - `events` - List of events (if include_events was true)
    - `as_of` - The timestamp reconstructed to
    """

    use Jido.Action,
      name: "historian_reconstruct_state",
      description: "Reconstruct system state at a point in time via event replay",
      category: "historian",
      tags: ["historian", "state", "replay", "debug"],
      schema: [
        stream: [
          type: :string,
          required: true,
          doc: "Stream to reconstruct (e.g., 'agent:agent_001')"
        ],
        as_of: [
          type: :string,
          required: true,
          doc: "Timestamp to reconstruct to (ISO8601 format)"
        ],
        include_events: [
          type: :boolean,
          default: false,
          doc: "Include the events used in reconstruction"
        ]
      ]

    alias Arbor.Actions

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(%{stream: stream, as_of: as_of_str} = params, _context) do
      include_events = params[:include_events] || false

      Actions.emit_started(__MODULE__, %{stream: stream})

      with {:ok, as_of} <- parse_datetime(as_of_str),
           {:ok, events} <- fetch_events_up_to(stream, as_of) do
        state = reconstruct_from_events(events)

        result = %{
          state: state,
          event_count: length(events),
          as_of: DateTime.to_iso8601(as_of)
        }

        result = if include_events, do: Map.put(result, :events, events), else: result

        Actions.emit_completed(__MODULE__, %{
          stream: stream,
          event_count: length(events)
        })

        {:ok, result}
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, format_error(reason)}
      end
    end

    defp parse_datetime(str) when is_binary(str) do
      case DateTime.from_iso8601(str) do
        {:ok, dt, _offset} -> {:ok, dt}
        _ -> {:error, "Invalid datetime format: #{str}"}
      end
    end

    defp parse_datetime(%DateTime{} = dt), do: {:ok, dt}

    defp fetch_events_up_to(stream, as_of) do
      # Create a span from epoch to as_of
      epoch = ~U[1970-01-01 00:00:00Z]
      span = Arbor.Historian.span(from: epoch, to: as_of, streams: [stream])

      case Arbor.Historian.reconstruct(span) do
        {:ok, events} -> {:ok, events}
        error -> error
      end
    end

    defp reconstruct_from_events(events) do
      # Aggregate events into a state map
      # This is a simple implementation - real state reconstruction
      # would depend on the stream type and event schemas
      events
      |> Enum.reduce(%{}, fn event, acc ->
        # Extract key data from each event
        update = %{
          last_event_id: Map.get(event, :id) || Map.get(event, :signal_id),
          last_event_type: Map.get(event, :type),
          last_event_at: Map.get(event, :timestamp) || Map.get(event, :occurred_at)
        }

        # Merge metadata if present
        metadata = Map.get(event, :metadata, %{})

        acc
        |> Map.merge(update)
        |> Map.update(:event_types, [event[:type]], &[event[:type] | &1])
        |> Map.update(:metadata_keys, Map.keys(metadata), fn keys ->
          Enum.uniq(keys ++ Map.keys(metadata))
        end)
      end)
    end

    defp format_error({:unauthorized, reason}), do: "Unauthorized: #{inspect(reason)}"
    defp format_error(reason), do: "State reconstruction failed: #{inspect(reason)}"
  end

  defmodule TaintTrace do
    @moduledoc """
    Query taint chains through the historian.

    Provides agent-accessible taint provenance queries for tracing how tainted
    data flows through the system.

    ## Query Types

    | Type | Description |
    |------|-------------|
    | `:trace_backward` | Follow taint chain backward from a signal to its origin |
    | `:trace_forward` | Follow taint flow forward to see downstream effects |
    | `:events` | Query filtered taint events |
    | `:summary` | Get aggregated taint activity summary for an agent |

    ## Examples

        # Trace backward from an event
        {:ok, result} = Arbor.Actions.Historian.TaintTrace.run(
          %{query_type: :trace_backward, signal_id: "sig_123"},
          %{}
        )

        # Get taint summary for an agent
        {:ok, result} = Arbor.Actions.Historian.TaintTrace.run(
          %{query_type: :summary, agent_id: "agent_001"},
          %{}
        )

    ## Authorization

    Capability URI: `arbor://actions/execute/historian.taint_trace`
    Queries access the security stream, which may require additional capabilities.
    """

    use Jido.Action,
      name: "historian_taint_trace",
      description: "Trace taint provenance chains through the security event log",
      category: "historian",
      tags: ["historian", "security", "taint", "provenance", "trace"],
      schema: [
        query_type: [
          type: {:in, [:trace_backward, :trace_forward, :events, :summary]},
          required: true,
          doc: "Type of taint query: trace_backward, trace_forward, events, or summary"
        ],
        signal_id: [
          type: :string,
          doc: "Signal ID for trace_backward/trace_forward queries"
        ],
        agent_id: [
          type: :string,
          doc: "Agent ID for summary queries or filtering events"
        ],
        taint_level: [
          type: :atom,
          doc: "Filter by taint level (trusted, derived, untrusted, hostile)"
        ],
        event_type: [
          type: :atom,
          doc: "Filter by taint event type (taint_blocked, taint_propagated, etc.)"
        ],
        limit: [
          type: :integer,
          default: 100,
          doc: "Maximum number of results to return"
        ]
      ]

    alias Arbor.Actions

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(params, _context) do
      Actions.emit_started(__MODULE__, sanitize_params(params))

      result =
        case params.query_type do
          :trace_backward ->
            with {:ok, signal_id} <- require_param(params, :signal_id) do
              Arbor.Historian.trace_taint(signal_id, build_opts(params))
            end

          :trace_forward ->
            with {:ok, signal_id} <- require_param(params, :signal_id) do
              Arbor.Historian.taint_flow(signal_id, build_opts(params))
            end

          :events ->
            Arbor.Historian.taint_events(build_opts(params))

          :summary ->
            with {:ok, agent_id} <- require_param(params, :agent_id) do
              Arbor.Historian.taint_summary(agent_id, build_opts(params))
            end
        end

      case result do
        {:ok, data} ->
          Actions.emit_completed(__MODULE__, %{
            query_type: params.query_type,
            count: result_count(data)
          })

          {:ok, wrap_result(params.query_type, data)}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, format_error(reason)}
      end
    end

    defp require_param(params, key) do
      case Map.get(params, key) do
        nil -> {:error, {:missing_param, key}}
        "" -> {:error, {:missing_param, key}}
        value -> {:ok, value}
      end
    end

    defp build_opts(params) do
      []
      |> maybe_add(:taint_level, Map.get(params, :taint_level))
      |> maybe_add(:agent_id, Map.get(params, :agent_id))
      |> maybe_add(:event_type, Map.get(params, :event_type))
      |> maybe_add(:limit, Map.get(params, :limit))
    end

    defp maybe_add(opts, _key, nil), do: opts
    defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

    defp result_count(data) when is_list(data), do: length(data)
    defp result_count(data) when is_map(data), do: 1
    defp result_count(_), do: 0

    defp wrap_result(:trace_backward, chain) do
      %{chain: chain, depth: length(chain)}
    end

    defp wrap_result(:trace_forward, chain) do
      %{chain: chain, depth: length(chain)}
    end

    defp wrap_result(:events, events) do
      %{events: events, count: length(events)}
    end

    defp wrap_result(:summary, summary) do
      summary
    end

    defp sanitize_params(params) do
      Map.take(params, [:query_type, :signal_id, :agent_id, :taint_level, :event_type, :limit])
    end

    defp format_error({:missing_param, key}), do: "Missing required parameter: #{key}"
    defp format_error({:unauthorized, reason}), do: "Unauthorized: #{inspect(reason)}"
    defp format_error(reason), do: "Taint trace failed: #{inspect(reason)}"
  end
end
