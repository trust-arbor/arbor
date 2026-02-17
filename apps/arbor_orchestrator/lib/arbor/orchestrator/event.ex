defmodule Arbor.Orchestrator.Event do
  @moduledoc """
  Pipeline execution events emitted during orchestration.

  Provides typed constructor functions for all engine events.
  Events are dispatched via `Arbor.Orchestrator.EventEmitter` to all
  subscribers registered for the pipeline's run ID (or `:all`).

  Timestamps are added automatically by the engine's `emit/2` wrapper.
  """

  @type event_type ::
          :pipeline_started
          | :pipeline_completed
          | :pipeline_failed
          | :pipeline_resumed
          | :stage_started
          | :stage_completed
          | :stage_failed
          | :stage_retrying
          | :stage_skipped
          | :goal_gate_retrying
          | :fidelity_resolved
          | :checkpoint_saved
          | :fan_out_detected
          | :fan_out_branch_resuming
          | :fan_in_deferred
          | :loop_restart

  @type t :: %{
          required(:type) => event_type(),
          optional(:node_id) => String.t(),
          optional(:graph_id) => String.t(),
          optional(:status) => atom(),
          optional(:error) => term(),
          optional(:reason) => term(),
          optional(:duration_ms) => non_neg_integer(),
          optional(:timestamp) => DateTime.t()
        }

  # ---------------------------------------------------------------------------
  # Pipeline lifecycle
  # ---------------------------------------------------------------------------

  @doc "Build a pipeline_started event."
  def pipeline_started(graph_id, opts \\ []) do
    %{
      type: :pipeline_started,
      graph_id: graph_id,
      logs_root: Keyword.get(opts, :logs_root),
      node_count: Keyword.get(opts, :node_count)
    }
  end

  @doc "Build a pipeline_completed event."
  def pipeline_completed(completed_nodes, duration_ms) do
    %{type: :pipeline_completed, completed_nodes: completed_nodes, duration_ms: duration_ms}
  end

  @doc "Build a pipeline_failed event."
  def pipeline_failed(reason, duration_ms \\ nil) do
    event = %{type: :pipeline_failed, reason: reason}
    if duration_ms, do: Map.put(event, :duration_ms, duration_ms), else: event
  end

  @doc "Build a pipeline_resumed event."
  def pipeline_resumed(checkpoint_path, current_node) do
    %{type: :pipeline_resumed, checkpoint: checkpoint_path, current_node: current_node}
  end

  # ---------------------------------------------------------------------------
  # Stage lifecycle
  # ---------------------------------------------------------------------------

  @doc "Build a stage_started event."
  def stage_started(node_id) do
    %{type: :stage_started, node_id: node_id}
  end

  @doc "Build a stage_completed event."
  def stage_completed(node_id, status, opts \\ []) do
    event = %{type: :stage_completed, node_id: node_id, status: status}

    if duration = Keyword.get(opts, :duration_ms),
      do: Map.put(event, :duration_ms, duration),
      else: event
  end

  @doc "Build a stage_failed event."
  def stage_failed(node_id, error, opts \\ []) do
    %{type: :stage_failed, node_id: node_id, error: error}
    |> maybe_put(:will_retry, Keyword.get(opts, :will_retry))
    |> maybe_put(:duration_ms, Keyword.get(opts, :duration_ms))
  end

  @doc "Build a stage_retrying event."
  def stage_retrying(node_id, attempt, delay_ms) do
    %{type: :stage_retrying, node_id: node_id, attempt: attempt, delay_ms: delay_ms}
  end

  @doc "Build a stage_skipped event."
  def stage_skipped(node_id, reason) do
    %{type: :stage_skipped, node_id: node_id, reason: reason}
  end

  # ---------------------------------------------------------------------------
  # Fidelity & checkpoints
  # ---------------------------------------------------------------------------

  @doc "Build a fidelity_resolved event."
  def fidelity_resolved(node_id, mode, thread_id) do
    %{type: :fidelity_resolved, node_id: node_id, mode: mode, thread_id: thread_id}
  end

  @doc "Build a checkpoint_saved event."
  def checkpoint_saved(node_id, path) do
    %{type: :checkpoint_saved, node_id: node_id, path: path}
  end

  # ---------------------------------------------------------------------------
  # Fan-out / fan-in
  # ---------------------------------------------------------------------------

  @doc "Build a fan_out_detected event."
  def fan_out_detected(node_id, branch_count, targets) do
    %{type: :fan_out_detected, node_id: node_id, branch_count: branch_count, targets: targets}
  end

  @doc "Build a fan_out_branch_resuming event."
  def fan_out_branch_resuming(node_id, pending_count) do
    %{type: :fan_out_branch_resuming, node_id: node_id, pending_count: pending_count}
  end

  @doc "Build a fan_in_deferred event."
  def fan_in_deferred(node_id, waiting_for) do
    %{type: :fan_in_deferred, node_id: node_id, waiting_for: waiting_for}
  end

  # ---------------------------------------------------------------------------
  # Goal gate & loop control
  # ---------------------------------------------------------------------------

  @doc "Build a goal_gate_retrying event."
  def goal_gate_retrying(target) do
    %{type: :goal_gate_retrying, target: target}
  end

  @doc "Build a loop_restart event."
  def loop_restart(edge_from, edge_to) do
    %{type: :loop_restart, edge: %{from: edge_from, to: edge_to}, reason: :loop_restart_edge}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
