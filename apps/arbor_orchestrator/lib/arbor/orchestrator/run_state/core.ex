defmodule Arbor.Orchestrator.RunState.Core do
  @moduledoc """
  Pure business logic for pipeline run lifecycle.

  Follows the Construct-Reduce-Convert (CRC) pattern. All functions are
  pure and side-effect free — no ETS, no GenServer, no IO. The Engine
  holds a `%RunState{}` in its own process state and calls these functions
  to transition it. A thin boundary layer writes the result to ETS for
  external visibility.

  ## State Machine

      :running ──→ :completed
         │    ──→ :failed
         │    ──→ :abandoned
         │    ──→ :suspended ──→ :running (resume)
         │    ──→ :delegated
         │    ──→ :interrupted ──→ :running (recovery)
         │    ──→ :degraded (tracking broken, execution continues)

  ## Privacy by Default

  The struct stores ONLY metadata — IDs, status, timestamps, node names,
  durations. Agent goals, memory, working context, LLM prompts/responses
  NEVER enter this struct. They stay in the Engine's execution context.

  ## Pipeline

      RunState.Core.new(run_id, graph_id, 19, now: DateTime.utc_now())
      |> RunState.Core.node_started("bg_checks")
      |> RunState.Core.node_completed("bg_checks", 42)
      |> RunState.Core.mark_completed(5000)
      |> RunState.Core.to_ets_entry()
  """

  use TypedStruct

  @type status ::
          :running
          | :completed
          | :failed
          | :abandoned
          | :suspended
          | :delegated
          | :interrupted
          | :degraded

  typedstruct enforce: true do
    @typedoc "Pipeline run lifecycle state — metadata only, no agent context."

    field(:run_id, String.t())
    field(:pipeline_id, String.t())
    field(:graph_id, String.t())
    field(:status, status(), default: :running)
    field(:total_nodes, non_neg_integer(), default: 0)
    field(:completed_count, non_neg_integer(), default: 0)
    field(:completed_nodes, [String.t()], default: [])
    field(:current_node, String.t() | nil, default: nil, enforce: false)
    field(:node_durations, %{String.t() => non_neg_integer()}, default: %{})
    field(:started_at, DateTime.t())
    field(:finished_at, DateTime.t() | nil, default: nil, enforce: false)
    field(:duration_ms, non_neg_integer() | nil, default: nil, enforce: false)
    field(:failure_reason, term(), default: nil, enforce: false)
    field(:owner_node, atom(), enforce: false)
    field(:source_node, atom(), enforce: false)
    field(:spawning_pid, pid() | nil, default: nil, enforce: false)
    field(:last_heartbeat, DateTime.t(), enforce: false)
    # Council recommendation: "Last Synced" timestamp so the dashboard
    # can show "stale data" warnings when the Engine stops updating.
    field(:last_ets_sync, DateTime.t() | nil, default: nil, enforce: false)
  end

  # ===========================================================================
  # Construct
  # ===========================================================================

  @doc """
  Create a new run state for a pipeline execution.

  `now` must be passed explicitly (not `DateTime.utc_now()`) to keep
  this function pure. The Engine provides the timestamp.
  """
  @spec new(String.t(), String.t(), non_neg_integer(), keyword()) :: t()
  def new(run_id, graph_id, total_nodes, opts \\ []) do
    now = Keyword.fetch!(opts, :now)

    %__MODULE__{
      run_id: run_id,
      pipeline_id: Keyword.get(opts, :pipeline_id, run_id),
      graph_id: graph_id,
      status: :running,
      total_nodes: total_nodes,
      started_at: now,
      last_heartbeat: now,
      owner_node: Keyword.get(opts, :owner_node),
      source_node: Keyword.get(opts, :source_node),
      spawning_pid: Keyword.get(opts, :spawning_pid)
    }
  end

  # ===========================================================================
  # Reduce — state transitions
  # ===========================================================================

  @doc "Record that a node has started executing."
  @spec node_started(t(), String.t()) :: t()
  def node_started(%__MODULE__{status: :running} = state, node_id) do
    %{state | current_node: node_id}
  end

  def node_started(%__MODULE__{} = state, _node_id), do: state

  @doc "Record that a node completed successfully."
  @spec node_completed(t(), String.t(), non_neg_integer()) :: t()
  def node_completed(%__MODULE__{status: :running} = state, node_id, duration_ms) do
    %{
      state
      | current_node: nil,
        completed_count: state.completed_count + 1,
        completed_nodes: [node_id | state.completed_nodes],
        node_durations: Map.put(state.node_durations, node_id, duration_ms)
    }
  end

  def node_completed(%__MODULE__{} = state, _node_id, _duration_ms), do: state

  @doc "Record that a node failed."
  @spec node_failed(t(), String.t(), term()) :: t()
  def node_failed(%__MODULE__{status: :running} = state, node_id, reason) do
    %{state | current_node: node_id, failure_reason: {:node_failed, node_id, reason}}
  end

  def node_failed(%__MODULE__{} = state, _node_id, _reason), do: state

  @doc "Mark the pipeline as successfully completed."
  @spec mark_completed(t(), non_neg_integer(), keyword()) :: t()
  def mark_completed(state, duration_ms, opts \\ [])

  def mark_completed(%__MODULE__{status: :running} = state, duration_ms, opts) do
    now = Keyword.get(opts, :now, state.started_at)

    %{state | status: :completed, current_node: nil, duration_ms: duration_ms, finished_at: now}
  end

  def mark_completed(%__MODULE__{} = state, _duration_ms, _opts), do: state

  @doc "Mark the pipeline as failed."
  @spec mark_failed(t(), term(), non_neg_integer(), keyword()) :: t()
  def mark_failed(state, reason, duration_ms, opts \\ [])

  def mark_failed(%__MODULE__{status: status} = state, reason, duration_ms, opts)
      when status in [:running, :suspended] do
    now = Keyword.get(opts, :now, state.started_at)

    %{
      state
      | status: :failed,
        current_node: nil,
        failure_reason: reason,
        duration_ms: duration_ms,
        finished_at: now
    }
  end

  def mark_failed(%__MODULE__{} = state, _reason, _duration_ms, _opts), do: state

  @doc "Mark the pipeline as abandoned (will not be recovered)."
  @spec mark_abandoned(t()) :: t()
  def mark_abandoned(%__MODULE__{status: status} = state)
      when status in [:running, :interrupted, :suspended, :degraded] do
    %{state | status: :abandoned, current_node: nil}
  end

  def mark_abandoned(%__MODULE__{} = state), do: state

  @doc "Mark the pipeline as interrupted (eligible for recovery)."
  @spec mark_interrupted(t()) :: t()
  def mark_interrupted(%__MODULE__{status: :running} = state) do
    %{state | status: :interrupted, current_node: nil}
  end

  def mark_interrupted(%__MODULE__{} = state), do: state

  @doc "Mark the pipeline as suspended (waiting for capability or approval)."
  @spec mark_suspended(t(), term()) :: t()
  def mark_suspended(%__MODULE__{status: :running} = state, reason) do
    %{state | status: :suspended, failure_reason: reason}
  end

  def mark_suspended(%__MODULE__{} = state, _reason), do: state

  @doc "Mark the pipeline as delegated to another node or agent."
  @spec mark_delegated(t(), atom()) :: t()
  def mark_delegated(%__MODULE__{status: :running} = state, target_node) do
    %{state | status: :delegated, current_node: nil, failure_reason: {:delegated_to, target_node}}
  end

  def mark_delegated(%__MODULE__{} = state, _target_node), do: state

  @doc "Mark the pipeline as degraded (tracking broken, execution continues)."
  @spec mark_degraded(t()) :: t()
  def mark_degraded(%__MODULE__{status: :running} = state) do
    %{state | status: :degraded}
  end

  def mark_degraded(%__MODULE__{} = state), do: state

  @doc "Resume a suspended or interrupted pipeline."
  @spec resume(t()) :: t()
  def resume(%__MODULE__{status: status} = state)
      when status in [:suspended, :interrupted] do
    %{state | status: :running, failure_reason: nil}
  end

  def resume(%__MODULE__{} = state), do: state

  @doc "Update the heartbeat timestamp (for distributed liveness detection)."
  @spec touch_heartbeat(t(), DateTime.t()) :: t()
  def touch_heartbeat(%__MODULE__{} = state, now) do
    %{state | last_heartbeat: now}
  end

  @doc "Record that the state was synced to ETS."
  @spec mark_synced(t(), DateTime.t()) :: t()
  def mark_synced(%__MODULE__{} = state, now) do
    %{state | last_ets_sync: now}
  end

  # ===========================================================================
  # Convert — for display and ETS persistence
  # ===========================================================================

  @doc """
  Convert to a map suitable for ETS storage.

  Returns ONLY metadata — no agent context, no LLM content, no tool
  results. This is the "public schema" that the Facade exposes to
  dashboards and status queries.
  """
  @spec to_ets_entry(t()) :: map()
  def to_ets_entry(%__MODULE__{} = state) do
    %{
      run_id: state.run_id,
      pipeline_id: state.pipeline_id,
      graph_id: state.graph_id,
      status: state.status,
      total_nodes: state.total_nodes,
      completed_count: state.completed_count,
      completed_nodes: Enum.reverse(state.completed_nodes),
      current_node: state.current_node,
      node_durations: state.node_durations,
      started_at: state.started_at,
      finished_at: state.finished_at,
      duration_ms: state.duration_ms,
      failure_reason: sanitize_failure_reason(state.failure_reason),
      owner_node: state.owner_node,
      source_node: state.source_node,
      spawning_pid: state.spawning_pid,
      last_heartbeat: state.last_heartbeat,
      last_ets_sync: state.last_ets_sync
    }
  end

  @doc "Human-readable progress string."
  @spec show_progress(t()) :: String.t()
  def show_progress(%__MODULE__{} = state) do
    node_info = if state.current_node, do: ", current: #{state.current_node}", else: ""
    "#{state.completed_count}/#{state.total_nodes} nodes#{node_info}"
  end

  @doc "Summary map for display."
  @spec show_summary(t()) :: map()
  def show_summary(%__MODULE__{} = state) do
    %{
      status: state.status,
      progress: show_progress(state),
      duration_ms: state.duration_ms,
      graph_id: state.graph_id,
      run_id: state.run_id
    }
  end

  # ===========================================================================
  # Queries (pure, over the state)
  # ===========================================================================

  @doc "Is the pipeline currently active (running or suspended)?"
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{status: status}), do: status in [:running, :suspended, :degraded]

  @doc "Has the pipeline reached a terminal state?"
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: status in [:completed, :failed, :abandoned]

  @doc "Is the pipeline's heartbeat older than the given threshold?"
  @spec stale?(t(), non_neg_integer(), DateTime.t()) :: boolean()
  def stale?(%__MODULE__{last_heartbeat: last}, threshold_ms, now) do
    DateTime.diff(now, last, :millisecond) > threshold_ms
  end

  # ===========================================================================
  # Private
  # ===========================================================================

  # Strip potentially sensitive details from failure reasons before ETS storage.
  # Keep the structure (for display) but remove any nested data that might
  # contain agent context.
  defp sanitize_failure_reason(nil), do: nil
  defp sanitize_failure_reason({:node_failed, node_id, _reason}), do: {:node_failed, node_id}
  defp sanitize_failure_reason({:delegated_to, node}), do: {:delegated_to, node}
  defp sanitize_failure_reason(reason) when is_atom(reason), do: reason
  defp sanitize_failure_reason(reason) when is_binary(reason), do: reason
  defp sanitize_failure_reason(_), do: :redacted
end
