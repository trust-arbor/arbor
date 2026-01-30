defmodule Arbor.Historian.QueryEngine do
  @moduledoc """
  Stateless query module over the EventLog.

  Reads events from EventLog streams and converts them to HistoryEntries.
  Provides convenience functions for common access patterns.
  """

  alias Arbor.Historian.EventConverter
  alias Arbor.Historian.HistoryEntry
  alias Arbor.Historian.StreamIds
  alias Arbor.Persistence.EventLog.ETS, as: PersistenceETS

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

    case PersistenceETS.read_stream(stream_id, name: event_log) do
      {:ok, persistence_events} ->
        entries =
          persistence_events
          |> Enum.map(&convert_to_history_entry/1)
          |> Enum.reject(&is_nil/1)

        {:ok, entries}

      error ->
        error
    end
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
end
