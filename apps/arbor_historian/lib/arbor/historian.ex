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
      span = Arbor.Historian.span(from: one_hour_ago, to: now)
      {:ok, entries} = Arbor.Historian.reconstruct(span)

      # Get statistics
      stats = Arbor.Historian.stats()
  """

  @behaviour Arbor.Contracts.API.Historian

  alias Arbor.Historian.{QueryEngine, StreamRegistry, TaintQuery, Timeline}
  alias Arbor.Historian.QueryEngine.Aggregator
  alias Arbor.Historian.Timeline.Span

  # ── Authorized API (for agent callers) ──

  @doc """
  Query history entries with authorization check.

  Verifies the agent has the `arbor://historian/query/{stream}` capability
  before querying. Use this for agent-initiated queries where authorization
  should be enforced.

  ## Parameters

  - `agent_id` - The agent's ID for capability lookup
  - `query_opts` - Query options including `:category`, `:type`, `:source`, etc.
    The `:category` option determines the stream for authorization (default: "general")
  - `opts` - Additional options, including optional `:trace_id` for correlation

  ## Returns

  - `{:ok, entries}` on success
  - `{:error, {:unauthorized, reason}}` if agent lacks the required capability
  - `{:ok, :pending_approval, proposal_id}` if escalation needed
  """
  @spec authorize_query(String.t(), keyword(), keyword()) ::
          {:ok, [map()]}
          | {:ok, :pending_approval, String.t()}
          | {:error, {:unauthorized, term()}}
  def authorize_query(agent_id, query_opts \\ [], opts \\ []) do
    stream = extract_stream_from_query(query_opts)
    resource = "arbor://historian/query/#{stream}"
    {trace_id, _opts} = Keyword.pop(opts, :trace_id)

    case Arbor.Security.authorize(agent_id, resource, :query, trace_id: trace_id) do
      {:ok, :authorized} ->
        query(query_opts)

      {:ok, :pending_approval, proposal_id} ->
        {:ok, :pending_approval, proposal_id}

      {:error, reason} ->
        {:error, {:unauthorized, reason}}
    end
  end

  @doc """
  Query entries for a specific category with authorization check.

  Verifies the agent has the `arbor://historian/query/{category}` capability.
  Sensitive categories like `:security` and `:identity` require explicit capabilities.

  ## Parameters

  - `agent_id` - The agent's ID for capability lookup
  - `category` - The category to query (e.g., `:security`, `:agent`, `:shell`)
  - `query_opts` - Additional query options
  - `opts` - Additional options, including optional `:trace_id` for correlation

  ## Returns

  - `{:ok, entries}` on success
  - `{:error, {:unauthorized, reason}}` if agent lacks the required capability
  - `{:ok, :pending_approval, proposal_id}` if escalation needed
  """
  @spec authorize_for_category(String.t(), atom(), keyword(), keyword()) ::
          {:ok, [map()]}
          | {:ok, :pending_approval, String.t()}
          | {:error, {:unauthorized, term()}}
  def authorize_for_category(agent_id, category, query_opts \\ [], opts \\ []) do
    resource = "arbor://historian/query/#{category}"
    {trace_id, _opts} = Keyword.pop(opts, :trace_id)

    case Arbor.Security.authorize(agent_id, resource, :query, trace_id: trace_id) do
      {:ok, :authorized} ->
        for_category(category, query_opts)

      {:ok, :pending_approval, proposal_id} ->
        {:ok, :pending_approval, proposal_id}

      {:error, reason} ->
        {:error, {:unauthorized, reason}}
    end
  end

  @doc """
  Query entries for a specific agent with authorization check.

  Verifies the agent has the `arbor://historian/query/agent` capability
  before querying. Agents may be allowed to query their own history with
  a more limited capability.

  ## Parameters

  - `caller_id` - The calling agent's ID for capability lookup
  - `target_agent_id` - The agent ID to query history for
  - `query_opts` - Additional query options
  - `opts` - Additional options, including optional `:trace_id` for correlation

  ## Returns

  - `{:ok, entries}` on success
  - `{:error, {:unauthorized, reason}}` if agent lacks the required capability
  - `{:ok, :pending_approval, proposal_id}` if escalation needed
  """
  @spec authorize_for_agent(String.t(), String.t(), keyword(), keyword()) ::
          {:ok, [map()]}
          | {:ok, :pending_approval, String.t()}
          | {:error, {:unauthorized, term()}}
  def authorize_for_agent(caller_id, target_agent_id, query_opts \\ [], opts \\ []) do
    resource = "arbor://historian/query/agent"
    {trace_id, _opts} = Keyword.pop(opts, :trace_id)

    case Arbor.Security.authorize(caller_id, resource, :query, trace_id: trace_id) do
      {:ok, :authorized} ->
        for_agent(target_agent_id, query_opts)

      {:ok, :pending_approval, proposal_id} ->
        {:ok, :pending_approval, proposal_id}

      {:error, reason} ->
        {:error, {:unauthorized, reason}}
    end
  end

  @doc """
  Query recent entries with authorization check.

  Verifies the agent has the `arbor://historian/query/global` capability
  before reading the global stream.

  ## Parameters

  - `agent_id` - The agent's ID for capability lookup
  - `query_opts` - Query options for pagination, etc.
  - `opts` - Additional options, including optional `:trace_id` for correlation

  ## Returns

  - `{:ok, entries}` on success
  - `{:error, {:unauthorized, reason}}` if agent lacks the required capability
  - `{:ok, :pending_approval, proposal_id}` if escalation needed
  """
  @spec authorize_recent(String.t(), keyword(), keyword()) ::
          {:ok, [map()]}
          | {:ok, :pending_approval, String.t()}
          | {:error, {:unauthorized, term()}}
  def authorize_recent(agent_id, query_opts \\ [], opts \\ []) do
    resource = "arbor://historian/query/global"
    {trace_id, _opts} = Keyword.pop(opts, :trace_id)

    case Arbor.Security.authorize(agent_id, resource, :query, trace_id: trace_id) do
      {:ok, :authorized} ->
        recent(query_opts)

      {:ok, :pending_approval, proposal_id} ->
        {:ok, :pending_approval, proposal_id}

      {:error, reason} ->
        {:error, {:unauthorized, reason}}
    end
  end

  # Extract stream name from query options for authorization
  defp extract_stream_from_query(query_opts) do
    cond do
      Keyword.has_key?(query_opts, :category) ->
        query_opts[:category] |> to_string()

      Keyword.has_key?(query_opts, :stream) ->
        query_opts[:stream] |> to_string()

      true ->
        "general"
    end
  end

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

  # ── Span Construction ──

  @doc """
  Create a time span for timeline queries.

  ## Required Options

  - `:from` - Start time (`DateTime`)
  - `:to` - End time (`DateTime`)

  ## Optional

  - `:streams` - Restrict to specific stream IDs
  - `:categories` - Filter by category atoms
  - `:types` - Filter by type atoms
  - `:agent_id` - Filter by agent
  - `:correlation_id` - Filter by correlation chain
  """
  @spec span(keyword()) :: Span.t()
  defdelegate span(opts), to: Span, as: :new

  @doc "Create a span covering the last N minutes from now."
  @spec last_minutes(pos_integer(), keyword()) :: Span.t()
  defdelegate last_minutes(minutes, opts \\ []), to: Span

  @doc "Create a span covering the last N hours from now."
  @spec last_hours(pos_integer(), keyword()) :: Span.t()
  defdelegate last_hours(hours, opts \\ []), to: Span

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

  # ── Taint Provenance ──

  @doc """
  Trace a taint chain backward from a signal/event.

  Starting from a signal_id or event, follows taint_propagated events
  backward via their source references to reconstruct the full provenance chain.

  Returns events ordered from oldest (origin) to newest (the queried event).

  ## Options

  - `:max_depth` — maximum chain depth (default 50)
  - `:event_log` — test injection for EventLog name

  ## Examples

      {:ok, chain} = Arbor.Historian.trace_taint("sig_abc123")
  """
  @spec trace_taint(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate trace_taint(signal_id, opts \\ []), to: TaintQuery, as: :trace_backward

  @doc """
  Trace taint flow forward from a source signal.

  Starting from a source signal_id, finds all downstream taint_propagated
  events to show how taint spread through the system.

  ## Options

  - `:max_depth` — maximum chain depth (default 50)
  - `:event_log` — test injection for EventLog name

  ## Examples

      {:ok, downstream} = Arbor.Historian.taint_flow("sig_abc123")
  """
  @spec taint_flow(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate taint_flow(source_signal_id, opts \\ []), to: TaintQuery, as: :trace_forward

  @doc """
  Query taint events filtered by level, agent, time range, etc.

  ## Options

  - `:taint_level` — filter by taint level (atom: :trusted, :derived, :untrusted, :hostile)
  - `:agent_id` — filter by agent
  - `:event_type` — filter by taint event type (:taint_blocked, :taint_propagated, :taint_reduced, :taint_audited)
  - `:from` / `:to` — time range
  - `:limit` — max results (default 100)
  - `:event_log` — test injection for EventLog name

  ## Examples

      {:ok, events} = Arbor.Historian.taint_events(agent_id: "agent_001", limit: 50)
  """
  @spec taint_events(keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate taint_events(opts \\ []), to: TaintQuery, as: :query_taint_events

  @doc """
  Get a summary of taint activity for an agent.

  Returns counts by event type, most common taint levels, recent blocks, etc.

  ## Options

  - `:from` / `:to` — time range
  - `:event_log` — test injection for EventLog name

  ## Returns

  A map with:
  - `blocked_count` - Number of taint blocks
  - `propagated_count` - Number of taint propagations
  - `audited_count` - Number of audit-only events
  - `reduced_count` - Number of taint reductions
  - `total_count` - Total taint events
  - `taint_level_distribution` - Frequency map by taint level
  - `most_common_blocked_actions` - Top 5 blocked actions
  - `recent_blocks` - Last 5 blocked attempts

  ## Examples

      {:ok, summary} = Arbor.Historian.taint_summary("agent_001")
  """
  @spec taint_summary(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate taint_summary(agent_id, opts \\ []), to: TaintQuery

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
