defmodule Arbor.Historian.Timeline do
  @moduledoc """
  Cross-stream timeline reconstruction with deduplication.

  Merges events from multiple streams into a single chronologically-ordered
  timeline, deduplicating by signal_id. Supports causality chain following.
  """

  require Logger

  alias Arbor.Historian.HistoryEntry
  alias Arbor.Historian.QueryEngine
  alias Arbor.Historian.QueryEngine.Aggregator
  alias Arbor.Historian.StreamIds
  alias Arbor.Historian.Timeline.Span

  @default_max_results 10_000

  @doc """
  Reconstruct a timeline from a Span specification.

  Reads entries from the specified streams (or global if none specified),
  deduplicates by signal_id, applies category/type/time filters, and
  returns entries in chronological order.
  """
  @spec reconstruct(Span.t(), keyword()) :: {:ok, [HistoryEntry.t()]}
  def reconstruct(%Span{} = span, opts) do
    max_results = Keyword.get(opts, :max_results, @default_max_results)
    streams = determine_streams(span)

    entries =
      streams
      |> read_all_streams(opts)
      |> deduplicate()
      |> filter_by_span(span)
      |> Enum.sort_by(& &1.timestamp, DateTime)
      |> enforce_limit(max_results)

    {:ok, entries}
  end

  @doc """
  Get a timeline for a specific agent within a time range.
  """
  @spec for_agent(String.t(), DateTime.t(), DateTime.t(), keyword()) ::
          {:ok, [HistoryEntry.t()]}
  def for_agent(agent_id, from, to, opts) do
    span = Span.new(from: from, to: to, agent_id: agent_id)
    reconstruct(span, opts)
  end

  @doc """
  Get a timeline for a correlation chain.
  """
  @spec for_correlation(String.t(), keyword()) :: {:ok, [HistoryEntry.t()]}
  def for_correlation(correlation_id, opts) do
    QueryEngine.read_correlation(correlation_id, opts)
  end

  @doc """
  Follow a causality chain starting from a signal ID.

  Traces forward (effects) and backward (causes) through cause_id links.
  """
  @spec for_causality_chain(String.t(), keyword()) :: {:ok, [HistoryEntry.t()]}
  def for_causality_chain(signal_id, opts) do
    # Enforce a read limit to prevent loading unbounded data into memory
    opts = Keyword.put_new(opts, :limit, @default_max_results)
    {:ok, all_entries} = QueryEngine.read_global(opts)

    # Build a lookup by signal_id and by cause_id
    by_signal_id = Map.new(all_entries, &{&1.signal_id, &1})
    by_cause_id = Enum.group_by(all_entries, & &1.cause_id)

    # Trace backward (causes)
    causes = trace_backward(signal_id, by_signal_id, MapSet.new())
    # Trace forward (effects)
    effects = trace_forward(signal_id, by_cause_id, MapSet.new())

    # Combine, include the root entry
    root = Map.get(by_signal_id, signal_id)
    root_list = if root, do: [root], else: []

    chain =
      (Enum.reverse(causes) ++ root_list ++ effects)
      |> Enum.uniq_by(& &1.signal_id)
      |> Enum.sort_by(& &1.timestamp, DateTime)

    {:ok, chain}
  end

  @doc """
  Get a summary of a span.

  Returns aggregate statistics: total count, category breakdown,
  first/last timestamps, error count.
  """
  @spec summary(Span.t(), keyword()) :: map()
  def summary(%Span{} = span, opts) do
    {:ok, entries} = reconstruct(span, opts)
    Aggregator.build_summary(entries)
  end

  # Private helpers

  defp determine_streams(%Span{streams: streams}) when streams != [] do
    streams
  end

  defp determine_streams(%Span{agent_id: agent_id}) when is_binary(agent_id) do
    [StreamIds.for_agent(agent_id)]
  end

  defp determine_streams(%Span{correlation_id: cid}) when is_binary(cid) do
    [StreamIds.for_correlation(cid)]
  end

  defp determine_streams(%Span{categories: categories}) when categories != [] do
    Enum.map(categories, &StreamIds.for_category/1)
  end

  defp determine_streams(_span) do
    ["global"]
  end

  defp read_all_streams(stream_ids, opts) do
    Enum.flat_map(stream_ids, fn stream_id ->
      case QueryEngine.read_stream(stream_id, opts) do
        {:ok, entries} -> entries
        _ -> []
      end
    end)
  end

  defp deduplicate(entries) do
    entries
    |> Enum.uniq_by(& &1.signal_id)
  end

  defp filter_by_span(entries, %Span{} = span) do
    entries
    |> filter_by_time(span)
    |> filter_by_categories(span)
    |> filter_by_types(span)
  end

  defp filter_by_time(entries, %Span{from: from, to: to}) do
    Enum.filter(entries, fn entry ->
      DateTime.compare(entry.timestamp, from) in [:gt, :eq] and
        DateTime.compare(entry.timestamp, to) in [:lt, :eq]
    end)
  end

  defp filter_by_categories(entries, %Span{categories: []}), do: entries

  defp filter_by_categories(entries, %Span{categories: categories}) do
    cat_set = MapSet.new(categories)
    Enum.filter(entries, &MapSet.member?(cat_set, &1.category))
  end

  defp filter_by_types(entries, %Span{types: []}), do: entries

  defp filter_by_types(entries, %Span{types: types}) do
    type_set = MapSet.new(types)
    Enum.filter(entries, &MapSet.member?(type_set, &1.type))
  end

  defp trace_backward(signal_id, by_signal_id, seen) do
    if MapSet.member?(seen, signal_id) do
      []
    else
      do_trace_backward(signal_id, by_signal_id, seen)
    end
  end

  defp do_trace_backward(signal_id, by_signal_id, seen) do
    case Map.get(by_signal_id, signal_id) do
      nil ->
        []

      entry ->
        seen = MapSet.put(seen, signal_id)
        trace_backward_from_entry(entry, signal_id, by_signal_id, seen)
    end
  end

  defp trace_backward_from_entry(entry, signal_id, by_signal_id, seen) do
    if entry.cause_id && entry.cause_id != signal_id do
      trace_backward(entry.cause_id, by_signal_id, seen) ++ [entry]
    else
      [entry]
    end
  end

  defp trace_forward(signal_id, by_cause_id, seen) do
    if MapSet.member?(seen, signal_id) do
      []
    else
      seen = MapSet.put(seen, signal_id)
      effects = Map.get(by_cause_id, signal_id, [])

      Enum.flat_map(effects, fn effect ->
        [effect | trace_forward(effect.signal_id, by_cause_id, seen)]
      end)
    end
  end

  defp enforce_limit(entries, max) when length(entries) > max do
    Logger.warning("Timeline query results truncated",
      total: length(entries),
      limit: max
    )

    Enum.take(entries, max)
  end

  defp enforce_limit(entries, _max), do: entries
end
