defmodule Arbor.Contracts.API.Historian do
  @moduledoc """
  Public API contract for the Arbor.Historian library.

  Defines the facade interface for the durable activity stream and audit log.

  ## Quick Start

      # Query recent activity
      {:ok, entries} = Arbor.Historian.recent()

      # Query by agent
      {:ok, entries} = Arbor.Historian.for_agent("agent_001")

      # Reconstruct a timeline
      span = Arbor.Historian.Timeline.Span.last_hours(1)
      {:ok, entries} = Arbor.Historian.reconstruct(span)

  ## Functional Groups

  | Group | Purpose |
  |-------|---------|
  | Collection | Ingest signals into permanent event storage |
  | Querying | Read history entries by agent, category, session, etc. |
  | Aggregation | Compute counts, distributions, and activity summaries |
  | Timeline | Reconstruct ordered timelines and causality chains |
  | Streams | Inspect stream metadata and statistics |
  """

  # ===========================================================================
  # Types
  # ===========================================================================

  @type history_entry :: map()
  @type agent_id :: String.t()
  @type signal_id :: String.t()
  @type session_id :: String.t()
  @type correlation_id :: String.t()
  @type stream_id :: String.t()
  @type category :: atom()
  @type span :: struct()
  @type query_opts :: keyword()

  # ===========================================================================
  # Collection
  # ===========================================================================

  @doc """
  Collect a signal into the historian event log.

  Transforms the signal into a history entry and persists it to the
  appropriate streams.
  """
  @callback collect_signal_into_event_log(signal :: struct()) ::
              :ok | {:error, term()}

  @doc """
  Read the total number of events collected by the historian.
  """
  @callback read_collected_event_count() :: non_neg_integer()

  # ===========================================================================
  # Querying
  # ===========================================================================

  @doc """
  Read recent history entries from the global stream.

  Returns entries ordered newest-last. Accepts query options such as
  `:limit` to cap the number of results.
  """
  @callback read_recent_history_entries(query_opts()) ::
              {:ok, [history_entry()]}

  @doc """
  Read history entries for a specific agent.
  """
  @callback read_history_entries_for_agent(agent_id(), query_opts()) ::
              {:ok, [history_entry()]}

  @doc """
  Read history entries for a specific signal category.
  """
  @callback read_history_entries_for_category(category(), query_opts()) ::
              {:ok, [history_entry()]}

  @doc """
  Read history entries for a specific session.
  """
  @callback read_history_entries_for_session(session_id(), query_opts()) ::
              {:ok, [history_entry()]}

  @doc """
  Read history entries for a specific correlation chain.
  """
  @callback read_history_entries_for_correlation(correlation_id(), query_opts()) ::
              {:ok, [history_entry()]}

  @doc """
  Query history entries with filters.

  Supports filters such as `:category`, `:type`, `:source`, `:from`,
  `:to`, and `:limit`.
  """
  @callback query_history_entries_with_filters(query_opts()) ::
              {:ok, [history_entry()]}

  @doc """
  Find a single history entry by its original signal ID.
  """
  @callback find_history_entry_by_signal_id(signal_id(), query_opts()) ::
              {:ok, history_entry()} | {:error, :not_found}

  # ===========================================================================
  # Aggregation
  # ===========================================================================

  @doc """
  Count history entries for a given category.
  """
  @callback count_history_entries_by_category(category(), query_opts()) ::
              non_neg_integer()

  @doc """
  Count error and warning history entries.
  """
  @callback count_error_history_entries(query_opts()) :: non_neg_integer()

  @doc """
  Get the distribution of history entries across categories.

  Returns a map of `%{category => count}`.
  """
  @callback read_category_distribution(query_opts()) :: map()

  @doc """
  Get the distribution of history entries across signal types.

  Returns a map of `%{type => count}`.
  """
  @callback read_type_distribution(query_opts()) :: map()

  @doc """
  Get an activity summary for a specific agent.

  Returns a map containing entry counts, category breakdown, and
  recent activity metadata.
  """
  @callback read_agent_activity_summary(agent_id(), query_opts()) :: map()

  # ===========================================================================
  # Timeline
  # ===========================================================================

  @doc """
  Reconstruct a timeline of history entries for a given time span.

  Merges and deduplicates entries from multiple streams into a
  chronologically ordered list.
  """
  @callback reconstruct_timeline_for_span(span(), query_opts()) ::
              {:ok, [history_entry()]}

  @doc """
  Get a timeline for a specific agent within a time range.
  """
  @callback read_timeline_for_agent(
              agent_id(),
              from :: DateTime.t(),
              to :: DateTime.t(),
              query_opts()
            ) :: {:ok, [history_entry()]}

  @doc """
  Follow a causality chain from a signal ID.

  Traces the cause/effect chain through correlated signals.
  """
  @callback read_causality_chain_for_signal(signal_id(), query_opts()) ::
              {:ok, [history_entry()]}

  @doc """
  Get a summary of a timeline span.

  Returns aggregate statistics for the given time window.
  """
  @callback read_timeline_summary_for_span(span(), query_opts()) :: map()

  # ===========================================================================
  # Streams
  # ===========================================================================

  @doc """
  List all known stream IDs.
  """
  @callback list_all_stream_ids() :: [stream_id()]

  @doc """
  Get metadata for a specific stream by ID.
  """
  @callback read_stream_info_by_id(stream_id()) ::
              {:ok, map()} | {:error, :not_found}

  @doc """
  Get metadata for all streams.

  Returns a map keyed by stream ID.
  """
  @callback read_all_streams_metadata() :: map()

  @doc """
  Get overall historian statistics.

  Returns a map containing event counts, stream counts, and
  collector statistics.
  """
  @callback read_historian_stats() :: map()

  # ===========================================================================
  # Lifecycle
  # ===========================================================================

  @doc """
  Start the historian system.
  """
  @callback start_link(opts :: keyword()) :: GenServer.on_start()

  @doc """
  Check if the historian system is running and healthy.
  """
  @callback healthy?() :: boolean()

  # ===========================================================================
  # Optional Callbacks
  # ===========================================================================

  @optional_callbacks [
    # Aggregation
    count_history_entries_by_category: 2,
    count_error_history_entries: 1,
    read_category_distribution: 1,
    read_type_distribution: 1,
    read_agent_activity_summary: 2,
    # Timeline
    reconstruct_timeline_for_span: 2,
    read_timeline_for_agent: 4,
    read_causality_chain_for_signal: 2,
    read_timeline_summary_for_span: 2,
    # Streams
    list_all_stream_ids: 0,
    read_stream_info_by_id: 1,
    read_all_streams_metadata: 0,
    read_historian_stats: 0
  ]
end
