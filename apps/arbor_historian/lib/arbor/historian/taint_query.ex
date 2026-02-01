defmodule Arbor.Historian.TaintQuery do
  @moduledoc """
  Query and reconstruct taint chains from security events.

  All taint events live in the security stream. Each taint_propagated event
  carries denormalized source context, so chain reconstruction is a
  filter + link operation on security events alone.

  ## Event Types

  This module queries four types of taint events:

  | Type | Purpose |
  |------|---------|
  | `:taint_blocked` | Untrusted/hostile data blocked from control parameter |
  | `:taint_propagated` | Taint context propagated through action execution |
  | `:taint_reduced` | Taint level reduced (e.g., via human review) |
  | `:taint_audited` | Derived data used in control param (permissive policy) |

  ## Usage

      # Query all taint events for an agent
      {:ok, events} = TaintQuery.query_taint_events(agent_id: "agent_001")

      # Trace backward from a signal
      {:ok, chain} = TaintQuery.trace_backward(signal_id)

      # Get summary of taint activity
      {:ok, summary} = TaintQuery.taint_summary("agent_001")
  """

  alias Arbor.Common.SafeAtom
  alias Arbor.Historian.QueryEngine
  alias Arbor.Historian.HistoryEntry
  alias Arbor.Historian.StreamIds

  @taint_event_types [:taint_blocked, :taint_propagated, :taint_reduced, :taint_audited]
  @max_chain_depth 50

  @doc """
  Query taint events filtered by level, agent, time range, etc.

  ## Options

  - `:taint_level` — filter by taint level (atom: :trusted, :derived, :untrusted, :hostile)
  - `:agent_id` — filter by agent
  - `:event_type` — filter by taint event type (:taint_blocked, :taint_propagated, :taint_reduced, :taint_audited)
  - `:from` / `:to` — time range
  - `:limit` — max results (default 100)
  - `:event_log` — test injection for EventLog name
  """
  @spec query_taint_events(keyword()) :: {:ok, [HistoryEntry.t()]} | {:error, term()}
  def query_taint_events(opts \\ []) do
    with {:ok, entries} <- read_security_stream(opts) do
      filtered =
        entries
        |> filter_taint_events(opts)
        |> apply_limit(opts)

      {:ok, filtered}
    end
  end

  @doc """
  Trace a taint chain backward from a signal/event.

  Starting from a signal_id or event, follows taint_propagated events
  backward via their source references to reconstruct the full provenance chain.

  Returns events ordered from oldest (origin) to newest (the queried event).

  ## Options

  - `:max_depth` — maximum chain depth (default 50)
  - `:event_log` — test injection for EventLog name
  """
  @spec trace_backward(String.t(), keyword()) :: {:ok, [HistoryEntry.t()]} | {:error, term()}
  def trace_backward(signal_id, opts \\ []) when is_binary(signal_id) do
    max_depth = Keyword.get(opts, :max_depth, @max_chain_depth)

    with {:ok, entries} <- read_security_stream(opts) do
      # Filter to only taint_propagated events
      propagated_events =
        entries
        |> Enum.filter(&(&1.type == :taint_propagated))

      # Build a map of signal_id -> event for quick lookup
      # This allows us to find parent events by their signal_id
      events_by_signal_id =
        propagated_events
        |> Map.new(fn event -> {event.signal_id, event} end)

      # Find the starting event (by signal_id or matching context)
      start_event = find_event_by_signal_id(entries, signal_id)

      case start_event do
        nil ->
          # No matching event found
          {:ok, []}

        event ->
          # Trace backward from this event
          chain = build_chain_backward(event, events_by_signal_id, max_depth, [])
          {:ok, Enum.reverse(chain)}
      end
    end
  end

  @doc """
  Trace taint flow forward from a source signal.

  Starting from a source signal_id, finds all downstream taint_propagated
  events to show how taint spread through the system.

  ## Options

  - `:max_depth` — maximum chain depth (default 50)
  - `:event_log` — test injection for EventLog name
  """
  @spec trace_forward(String.t(), keyword()) :: {:ok, [HistoryEntry.t()]} | {:error, term()}
  def trace_forward(source_signal_id, opts \\ []) when is_binary(source_signal_id) do
    max_depth = Keyword.get(opts, :max_depth, @max_chain_depth)

    with {:ok, entries} <- read_security_stream(opts) do
      # Filter to only taint_propagated events
      propagated_events =
        entries
        |> Enum.filter(&(&1.type == :taint_propagated))

      # Find events that have this signal as their taint_source
      downstream = find_downstream_events(propagated_events, source_signal_id, max_depth, [])
      {:ok, downstream}
    end
  end

  @doc """
  Get a summary of taint activity for an agent.

  Returns counts by event type, most common taint levels, recent blocks, etc.

  ## Options

  - `:from` / `:to` — time range
  - `:event_log` — test injection for EventLog name
  """
  @spec taint_summary(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def taint_summary(agent_id, opts \\ []) when is_binary(agent_id) do
    with {:ok, entries} <- read_security_stream(opts) do
      # Filter to taint events for this agent
      agent_events =
        entries
        |> Enum.filter(&is_taint_event/1)
        |> Enum.filter(fn entry ->
          get_in(entry.data, [:agent_id]) == agent_id or
            get_in(entry.data, ["agent_id"]) == agent_id
        end)

      summary = build_summary(agent_events)
      {:ok, summary}
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp read_security_stream(opts) do
    stream_id = StreamIds.for_category(:security)
    QueryEngine.read_stream(stream_id, opts)
  end

  defp filter_taint_events(entries, opts) do
    entries
    |> Enum.filter(&is_taint_event/1)
    |> maybe_filter_by_taint_level(opts)
    |> maybe_filter_by_agent_id(opts)
    |> maybe_filter_by_event_type(opts)
    |> maybe_filter_by_time_range(opts)
  end

  defp is_taint_event(%HistoryEntry{type: type}) when type in @taint_event_types, do: true
  defp is_taint_event(_), do: false

  defp maybe_filter_by_taint_level(entries, opts) do
    case Keyword.get(opts, :taint_level) do
      nil ->
        entries

      level ->
        Enum.filter(entries, fn entry ->
          # Check for taint_level in data (for blocked/audited events)
          data_level = get_in(entry.data, [:taint_level]) || get_in(entry.data, ["taint_level"])
          # Check for input_taint (for propagated events)
          input_level = get_in(entry.data, [:input_taint]) || get_in(entry.data, ["input_taint"])

          normalize_level(data_level) == level or normalize_level(input_level) == level
        end)
    end
  end

  defp normalize_level(level) when is_atom(level), do: level

  defp normalize_level(level) when is_binary(level) do
    case SafeAtom.to_existing(level) do
      {:ok, atom} -> atom
      {:error, _} -> nil
    end
  end

  defp normalize_level(_), do: nil

  defp maybe_filter_by_agent_id(entries, opts) do
    case Keyword.get(opts, :agent_id) do
      nil ->
        entries

      agent_id ->
        Enum.filter(entries, fn entry ->
          get_in(entry.data, [:agent_id]) == agent_id or
            get_in(entry.data, ["agent_id"]) == agent_id
        end)
    end
  end

  defp maybe_filter_by_event_type(entries, opts) do
    case Keyword.get(opts, :event_type) do
      nil -> entries
      event_type -> Enum.filter(entries, &(&1.type == event_type))
    end
  end

  defp maybe_filter_by_time_range(entries, opts) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    entries
    |> maybe_filter_from(from)
    |> maybe_filter_to(to)
  end

  defp maybe_filter_from(entries, nil), do: entries

  defp maybe_filter_from(entries, from) do
    Enum.filter(entries, fn entry ->
      DateTime.compare(entry.timestamp, from) in [:gt, :eq]
    end)
  end

  defp maybe_filter_to(entries, nil), do: entries

  defp maybe_filter_to(entries, to) do
    Enum.filter(entries, fn entry ->
      DateTime.compare(entry.timestamp, to) in [:lt, :eq]
    end)
  end

  defp apply_limit(entries, opts) do
    case Keyword.get(opts, :limit, 100) do
      nil -> entries
      limit -> Enum.take(entries, limit)
    end
  end

  defp find_event_by_signal_id(entries, signal_id) do
    Enum.find(entries, fn entry ->
      entry.signal_id == signal_id or
        get_in(entry.data, [:signal_id]) == signal_id or
        get_in(entry.data, ["signal_id"]) == signal_id
    end)
  end

  # Build chain backward by following taint_source links
  defp build_chain_backward(_event, _events_by_signal_id, 0, acc), do: acc

  defp build_chain_backward(event, events_by_signal_id, depth, acc) do
    # Get the taint_source from this event - this is the signal_id of the parent event
    taint_source =
      get_in(event.data, [:taint_source]) || get_in(event.data, ["taint_source"])

    case taint_source do
      nil ->
        # End of chain - this is the origin
        [event | acc]

      source ->
        # Look up parent event by its signal_id
        case Map.get(events_by_signal_id, source) do
          nil ->
            # No parent found (source is external, not another event)
            # This is the effective origin
            [event | acc]

          parent ->
            # Continue tracing from the parent
            build_chain_backward(parent, events_by_signal_id, depth - 1, [event | acc])
        end
    end
  end

  # Find downstream events recursively
  defp find_downstream_events(_events, _source_id, 0, acc), do: Enum.reverse(acc)

  defp find_downstream_events(events, source_id, depth, acc) do
    # Find events that have this source_id as their taint_source
    direct_children =
      Enum.filter(events, fn entry ->
        taint_source =
          get_in(entry.data, [:taint_source]) || get_in(entry.data, ["taint_source"])

        taint_source == source_id
      end)

    case direct_children do
      [] ->
        Enum.reverse(acc)

      children ->
        # Add children to accumulator and recurse for each
        new_acc = acc ++ children

        # Get signal_ids of children to trace further
        child_ids =
          children
          |> Enum.map(& &1.signal_id)
          |> Enum.reject(&is_nil/1)

        # Recurse for each child's downstream
        Enum.reduce(child_ids, new_acc, fn child_id, acc_inner ->
          # Remove already-seen events to prevent infinite loops
          seen_ids = Enum.map(acc_inner, fn e -> e.signal_id end)
          remaining_events = Enum.reject(events, fn e -> e.signal_id in seen_ids end)
          find_downstream_events(remaining_events, child_id, depth - 1, acc_inner)
        end)
    end
  end

  defp build_summary(events) do
    # Count by event type
    type_counts =
      events
      |> Enum.group_by(& &1.type)
      |> Map.new(fn {type, list} -> {type, length(list)} end)

    # Taint level distribution (from blocked and audited events)
    level_events = Enum.filter(events, &(&1.type in [:taint_blocked, :taint_audited]))

    level_distribution =
      level_events
      |> Enum.map(fn entry ->
        get_in(entry.data, [:taint_level]) || get_in(entry.data, ["taint_level"])
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()

    # Recent blocks (last 5)
    recent_blocks =
      events
      |> Enum.filter(&(&1.type == :taint_blocked))
      |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
      |> Enum.take(5)
      |> Enum.map(fn entry ->
        %{
          action: get_in(entry.data, [:action]) || get_in(entry.data, ["action"]),
          parameter: get_in(entry.data, [:parameter]) || get_in(entry.data, ["parameter"]),
          taint_level: get_in(entry.data, [:taint_level]) || get_in(entry.data, ["taint_level"]),
          timestamp: entry.timestamp
        }
      end)

    # Most common blocked actions
    blocked_actions =
      events
      |> Enum.filter(&(&1.type == :taint_blocked))
      |> Enum.map(fn entry ->
        get_in(entry.data, [:action]) || get_in(entry.data, ["action"])
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_action, count} -> count end, :desc)
      |> Enum.take(5)
      |> Map.new()

    %{
      blocked_count: Map.get(type_counts, :taint_blocked, 0),
      propagated_count: Map.get(type_counts, :taint_propagated, 0),
      audited_count: Map.get(type_counts, :taint_audited, 0),
      reduced_count: Map.get(type_counts, :taint_reduced, 0),
      total_count: length(events),
      taint_level_distribution: level_distribution,
      most_common_blocked_actions: blocked_actions,
      recent_blocks: recent_blocks
    }
  end
end
