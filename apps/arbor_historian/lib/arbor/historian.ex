defmodule Arbor.Historian do
  @moduledoc """
  Pure query layer over persistent event storage for the Arbor system.

  Provides rich querying, timeline reconstruction, and causality tracing
  over events stored in the EventLog.

  ## Architecture

  ```
  EventLog (ETS)  ◄──  QueryEngine
       │                    │
  StreamRegistry         reads from:
  tracks:                - by stream
  - "global"             - by filter
  - "agent:{id}"         - aggregations
  - "category:{c}"
  - "session:{id}"       Timeline
  - "correlation:{id}"   merges + deduplicates
  ```

  ## Quick Start

      # Query recent activity
      {:ok, entries} = Arbor.Historian.recent()

      # Query by agent
      {:ok, entries} = Arbor.Historian.for_agent("agent_001")

      # Query by category
      {:ok, entries} = Arbor.Historian.for_category(:security)

      # Reconstruct a timeline
      span = Arbor.Historian.Timeline.Span.last_hours(1)
      {:ok, entries} = Arbor.Historian.reconstruct(span)

      # Get statistics
      stats = Arbor.Historian.stats()
  """

  @behaviour Arbor.Contracts.API.Historian

  alias Arbor.Historian.{QueryEngine, StreamRegistry, Timeline}
  alias Arbor.Historian.QueryEngine.Aggregator
  alias Arbor.Historian.Timeline.Span

  # ── Querying ──

  @doc "Read the global stream (all entries, newest last)."
  @spec recent(keyword()) :: {:ok, [QueryEngine.query_opts()]}
  defdelegate recent(opts \\ []), to: QueryEngine, as: :read_global

  @doc "Read entries for a specific agent."
  @spec for_agent(String.t(), keyword()) :: {:ok, [map()]}
  defdelegate for_agent(agent_id, opts \\ []), to: QueryEngine, as: :read_agent

  @doc "Read entries for a specific category."
  @spec for_category(atom(), keyword()) :: {:ok, [map()]}
  defdelegate for_category(category, opts \\ []), to: QueryEngine, as: :read_category

  @doc "Read entries for a specific session."
  @spec for_session(String.t(), keyword()) :: {:ok, [map()]}
  defdelegate for_session(session_id, opts \\ []), to: QueryEngine, as: :read_session

  @doc "Read entries for a specific correlation chain."
  @spec for_correlation(String.t(), keyword()) :: {:ok, [map()]}
  defdelegate for_correlation(correlation_id, opts \\ []), to: QueryEngine, as: :read_correlation

  @doc "Query with filters (category, type, source, from, to, limit)."
  @spec query(keyword()) :: {:ok, [map()]}
  defdelegate query(opts \\ []), to: QueryEngine

  @doc "Find a history entry by its original signal ID."
  @spec find_by_signal_id(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found}
  defdelegate find_by_signal_id(signal_id, opts \\ []), to: QueryEngine

  # ── Aggregation ──

  @doc "Count entries for a category."
  @spec count_by_category(atom(), keyword()) :: non_neg_integer()
  defdelegate count_by_category(category, opts \\ []), to: Aggregator

  @doc "Count error/warning entries."
  @spec error_count(keyword()) :: non_neg_integer()
  defdelegate error_count(opts \\ []), to: Aggregator

  @doc "Get category distribution."
  @spec category_distribution(keyword()) :: map()
  defdelegate category_distribution(opts \\ []), to: Aggregator

  @doc "Get type distribution."
  @spec type_distribution(keyword()) :: map()
  defdelegate type_distribution(opts \\ []), to: Aggregator

  @doc "Get activity summary for an agent."
  @spec agent_activity(String.t(), keyword()) :: map()
  defdelegate agent_activity(agent_id, opts \\ []), to: Aggregator

  # ── Timeline ──

  @doc "Reconstruct a timeline from a Span."
  @spec reconstruct(Span.t(), keyword()) :: {:ok, [map()]}
  defdelegate reconstruct(span, opts \\ []), to: Timeline

  @doc "Get a timeline for a specific agent within a time range."
  @spec timeline_for_agent(String.t(), DateTime.t(), DateTime.t(), keyword()) :: {:ok, [map()]}
  defdelegate timeline_for_agent(agent_id, from, to, opts \\ []), to: Timeline, as: :for_agent

  @doc "Follow a causality chain from a signal ID."
  @spec causality_chain(String.t(), keyword()) :: {:ok, [map()]}
  defdelegate causality_chain(signal_id, opts \\ []), to: Timeline, as: :for_causality_chain

  @doc "Get a summary of a timeline span."
  @spec timeline_summary(Span.t(), keyword()) :: map()
  defdelegate timeline_summary(span, opts \\ []), to: Timeline, as: :summary

  # ── Stream Registry ──

  @doc "List all known stream IDs."
  @spec streams() :: [String.t()]
  def streams do
    StreamRegistry.list_streams()
  end

  @doc "Get metadata for a specific stream."
  @spec stream_info(String.t()) :: {:ok, map()} | {:error, :not_found}
  def stream_info(stream_id) do
    StreamRegistry.get_stream(stream_id)
  end

  @doc "Get all stream metadata."
  @spec all_streams() :: map()
  def all_streams do
    StreamRegistry.all_streams()
  end

  # ── Stats ──

  @doc "Get overall historian statistics."
  @spec stats() :: map()
  def stats do
    stream_count = length(StreamRegistry.list_streams())
    total_events = StreamRegistry.total_events()

    %{
      stream_count: stream_count,
      total_events: total_events
    }
  end

  # ============================================================================
  # Contract Callbacks (Arbor.Contracts.API.Historian)
  # ============================================================================

  # -- Querying --

  @impl Arbor.Contracts.API.Historian
  def read_recent_history_entries(opts), do: QueryEngine.read_global(opts)

  @impl Arbor.Contracts.API.Historian
  def read_history_entries_for_agent(agent_id, opts),
    do: QueryEngine.read_agent(agent_id, opts)

  @impl Arbor.Contracts.API.Historian
  def read_history_entries_for_category(category, opts),
    do: QueryEngine.read_category(category, opts)

  @impl Arbor.Contracts.API.Historian
  def read_history_entries_for_session(session_id, opts),
    do: QueryEngine.read_session(session_id, opts)

  @impl Arbor.Contracts.API.Historian
  def read_history_entries_for_correlation(correlation_id, opts),
    do: QueryEngine.read_correlation(correlation_id, opts)

  @impl Arbor.Contracts.API.Historian
  def query_history_entries_with_filters(opts), do: QueryEngine.query(opts)

  @impl Arbor.Contracts.API.Historian
  def find_history_entry_by_signal_id(signal_id, opts),
    do: QueryEngine.find_by_signal_id(signal_id, opts)

  # -- Lifecycle --

  @impl Arbor.Contracts.API.Historian
  def start_link(_opts) do
    children = [
      {Arbor.Persistence.EventLog.ETS, name: Arbor.Historian.EventLog.ETS},
      {Arbor.Historian.StreamRegistry, name: Arbor.Historian.StreamRegistry}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Arbor.Historian.Supervisor)
  end

  @impl Arbor.Contracts.API.Historian
  def healthy? do
    case Process.whereis(Arbor.Historian.Supervisor) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  # -- Aggregation (optional) --

  @impl Arbor.Contracts.API.Historian
  def count_history_entries_by_category(category, opts),
    do: Aggregator.count_by_category(category, opts)

  @impl Arbor.Contracts.API.Historian
  def count_error_history_entries(opts), do: Aggregator.error_count(opts)

  @impl Arbor.Contracts.API.Historian
  def read_category_distribution(opts), do: Aggregator.category_distribution(opts)

  @impl Arbor.Contracts.API.Historian
  def read_type_distribution(opts), do: Aggregator.type_distribution(opts)

  @impl Arbor.Contracts.API.Historian
  def read_agent_activity_summary(agent_id, opts),
    do: Aggregator.agent_activity(agent_id, opts)

  # -- Timeline (optional) --

  @impl Arbor.Contracts.API.Historian
  def reconstruct_timeline_for_span(span, opts), do: Timeline.reconstruct(span, opts)

  @impl Arbor.Contracts.API.Historian
  def read_timeline_for_agent(agent_id, from, to, opts),
    do: Timeline.for_agent(agent_id, from, to, opts)

  @impl Arbor.Contracts.API.Historian
  def read_causality_chain_for_signal(signal_id, opts),
    do: Timeline.for_causality_chain(signal_id, opts)

  @impl Arbor.Contracts.API.Historian
  def read_timeline_summary_for_span(span, opts), do: Timeline.summary(span, opts)

  # -- Streams (optional) --

  @impl Arbor.Contracts.API.Historian
  def list_all_stream_ids, do: StreamRegistry.list_streams()

  @impl Arbor.Contracts.API.Historian
  def read_stream_info_by_id(stream_id), do: StreamRegistry.get_stream(stream_id)

  @impl Arbor.Contracts.API.Historian
  def read_all_streams_metadata, do: StreamRegistry.all_streams()

  @impl Arbor.Contracts.API.Historian
  def read_historian_stats, do: stats()
end
