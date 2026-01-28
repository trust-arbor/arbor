defmodule Arbor.Historian do
  @moduledoc """
  Durable activity stream and audit log for the Arbor system.

  Bridges transient signals (arbor_signals) with permanent event storage,
  providing rich querying, timeline reconstruction, and causality tracing.

  ## Architecture

  ```
  Signals.Bus  ──►  Collector  ──►  EventLog (ETS)
                        │                 │
                    StreamRouter      QueryEngine
                    routes to:        reads from:
                    - "global"        - by stream
                    - "agent:{id}"    - by filter
                    - "category:{c}"  - aggregations
                    - "session:{id}"
                    - "correlation:{id}"   Timeline
                                          merges + deduplicates
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

  alias Arbor.Historian.{Collector, QueryEngine, StreamRegistry, Timeline}
  alias Arbor.Historian.QueryEngine.Aggregator
  alias Arbor.Historian.Timeline.Span

  # ── Collection ──

  @doc "Manually collect a signal into the historian."
  @spec collect(struct()) :: :ok | {:error, term()}
  defdelegate collect(signal), to: Collector

  @doc "Get the number of events collected."
  @spec event_count() :: non_neg_integer()
  defdelegate event_count(), to: Collector

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
    collector_stats = Collector.stats()
    stream_count = length(StreamRegistry.list_streams())
    total_events = StreamRegistry.total_events()

    Map.merge(collector_stats, %{
      stream_count: stream_count,
      total_events: total_events
    })
  end
end
