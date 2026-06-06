defmodule Arbor.Historian.QueryEngine do
  @moduledoc """
  Stateless query module over the EventLog.

  Reads events from EventLog streams and converts them to HistoryEntries.
  Provides convenience functions for common access patterns.

  ## Cache-miss fallthrough

  The ETS EventLog is bounded by time-based retention (24h default). When
  a read requests events older than what's in cache, this module falls
  through to the durable Postgres backend for the full requested range
  and returns those results. The cache stays authoritative for recent
  reads (sub-microsecond); older reads pay one Postgres round-trip.

  Fallthrough is best-effort: if Postgres is unavailable or errors, the
  cache result is returned unchanged. Configurations without Postgres
  (SQLite-only setups, dev instances) get cache-only semantics, same as
  before.
  """

  require Logger

  alias Arbor.Historian.EventConverter
  alias Arbor.Historian.HistoryEntry
  alias Arbor.Historian.StreamIds
  alias Arbor.Persistence.EventLog.ETS, as: PersistenceETS
  alias Arbor.Persistence.EventLog.Postgres, as: PersistencePostgres
  alias Arbor.Signals

  @type query_opts :: [
          event_log: GenServer.server(),
          category: atom(),
          type: atom(),
          source: String.t(),
          correlation_id: String.t(),
          from: DateTime.t(),
          to: DateTime.t(),
          limit: pos_integer()
        ]

  @doc """
  Read all entries from a specific stream.
  """
  @spec read_stream(String.t(), keyword()) :: {:ok, [HistoryEntry.t()]}
  def read_stream(stream_id, opts) do
    event_log = Keyword.get(opts, :event_log, Arbor.Historian.EventLog.ETS)

    case fetch_events_with_fallthrough(stream_id, opts, event_log) do
      {:ok, persistence_events} ->
        entries =
          persistence_events
          |> Enum.map(&convert_to_history_entry/1)
          |> Enum.reject(&is_nil/1)

        {:ok, entries}

      {:error, reason} = error ->
        emit_query_failed(:read_stream, stream_id, reason)
        error
    end
  end

  # Try ETS first. If the cache's oldest event_number is greater than the
  # requested `from`, events in [from..oldest-1] have aged past retention
  # and only exist in Postgres — fetch the full range from there.
  #
  # Cache-only fallback when Postgres isn't running (SQLite setups, tests
  # without a Repo) — return whatever ETS gave us, log at debug level so
  # the divergence is observable without spamming.
  defp fetch_events_with_fallthrough(stream_id, opts, event_log) do
    ets_result = PersistenceETS.read_stream(stream_id, name: event_log)
    from = Keyword.get(opts, :from)

    # Fallthrough only applies when `:from` is an event_number (integer).
    # `query/1` passes DateTime values via `:from`/`:to` as post-filter
    # bounds — those aren't query-time event_number cursors and don't
    # trigger fallthrough. The cache result is post-filtered by the
    # caller.
    if is_integer(from) do
      maybe_fallthrough(stream_id, opts, from, event_log, ets_result)
    else
      ets_result
    end
  end

  defp maybe_fallthrough(stream_id, opts, from, event_log, ets_result) do
    with {:ok, _events} <- ets_result,
         {:ok, oldest} when not is_nil(oldest) <-
           PersistenceETS.oldest_event_number(stream_id, name: event_log),
         true <- oldest > from + 1,
         true <- postgres_available?() do
      case PersistencePostgres.read_stream(stream_id, opts) do
        {:ok, durable_events} ->
          {:ok, durable_events}

        {:error, reason} ->
          Logger.debug(
            "QueryEngine: fallthrough to Postgres failed for #{stream_id}: #{inspect(reason)}; serving cache result"
          )

          ets_result
      end
    else
      _ -> ets_result
    end
  end

  defp postgres_available? do
    repo = Arbor.Persistence.Repo
    Code.ensure_loaded?(repo) and Process.whereis(repo) != nil
  end

  @doc """
  Read entries for a specific agent.
  """
  @spec read_agent(String.t(), keyword()) :: {:ok, [HistoryEntry.t()]}
  def read_agent(agent_id, opts) do
    read_stream(StreamIds.for_agent(agent_id), opts)
  end

  @doc """
  Read entries for a specific category.
  """
  @spec read_category(atom(), keyword()) :: {:ok, [HistoryEntry.t()]}
  def read_category(category, opts) do
    read_stream(StreamIds.for_category(category), opts)
  end

  @doc """
  Read entries for a specific session.
  """
  @spec read_session(String.t(), keyword()) :: {:ok, [HistoryEntry.t()]}
  def read_session(session_id, opts) do
    read_stream(StreamIds.for_session(session_id), opts)
  end

  @doc """
  Read entries for a specific correlation chain.
  """
  @spec read_correlation(String.t(), keyword()) :: {:ok, [HistoryEntry.t()]}
  def read_correlation(correlation_id, opts) do
    read_stream(StreamIds.for_correlation(correlation_id), opts)
  end

  @doc """
  Read the global stream (all entries).
  """
  @spec read_global(keyword()) :: {:ok, [HistoryEntry.t()]}
  def read_global(opts) do
    read_stream("global", opts)
  end

  @doc """
  Query the global stream with filters applied.

  ## Options
  - `:category` - Filter by category atom
  - `:type` - Filter by type atom
  - `:source` - Filter by source string
  - `:correlation_id` - Filter by correlation ID
  - `:from` - Filter entries after this time
  - `:to` - Filter entries before this time
  - `:limit` - Maximum number of entries to return
  """
  @spec query(query_opts()) :: {:ok, [HistoryEntry.t()]}
  def query(opts) do
    {:ok, entries} = read_global(opts)

    filtered =
      entries
      |> apply_filters(opts)
      |> apply_limit(opts)

    {:ok, filtered}
  end

  @doc """
  Find a history entry by its original signal ID.

  Scans the global stream for a matching signal_id.
  """
  @spec find_by_signal_id(String.t(), keyword()) :: {:ok, HistoryEntry.t()} | {:error, :not_found}
  def find_by_signal_id(signal_id, opts) do
    {:ok, entries} = read_global(opts)

    case Enum.find(entries, &(&1.signal_id == signal_id)) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  # Private

  defp apply_filters(entries, opts) do
    filters =
      opts
      |> Keyword.take([:category, :type, :source, :correlation_id, :from, :to])
      |> Enum.into(%{})

    if map_size(filters) == 0 do
      entries
    else
      Enum.filter(entries, &HistoryEntry.matches?(&1, filters))
    end
  end

  defp apply_limit(entries, opts) do
    case Keyword.get(opts, :limit) do
      nil -> entries
      limit -> Enum.take(entries, limit)
    end
  end

  defp convert_to_history_entry(persistence_event) do
    case EventConverter.from_persistence_event(persistence_event) do
      {:ok, historian_event} -> HistoryEntry.from_event(historian_event)
      {:error, _} -> nil
    end
  end

  # Signal emission helper

  defp emit_query_failed(query_type, query_details, reason) do
    Signals.emit(:historian, :query_failed, %{
      query_type: query_type,
      query_details: truncate_details(query_details),
      reason: truncate_reason(reason)
    })
  end

  defp truncate_details(details) when is_binary(details) do
    if String.length(details) > 100 do
      String.slice(details, 0, 97) <> "..."
    else
      details
    end
  end

  defp truncate_details(details), do: inspect(details)

  defp truncate_reason(reason) do
    inspected = inspect(reason)

    if String.length(inspected) > 200 do
      String.slice(inspected, 0, 197) <> "..."
    else
      inspected
    end
  end
end
