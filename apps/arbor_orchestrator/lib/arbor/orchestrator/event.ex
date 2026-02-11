defmodule Arbor.Orchestrator.Event do
  @moduledoc """
  Pipeline execution events emitted during orchestration.

  Events are dispatched via `Arbor.Orchestrator.EventEmitter` to all
  subscribers registered for the pipeline's run ID (or `:all`).
  """

  @type event_type ::
          :pipeline_started
          | :pipeline_completed
          | :pipeline_failed
          | :stage_started
          | :stage_completed
          | :stage_failed
          | :stage_retrying
          | :goal_gate_retrying
          | :fidelity_resolved
          | :checkpoint_saved

  @type t :: %{
          required(:type) => event_type(),
          optional(:node_id) => String.t(),
          optional(:graph_id) => String.t(),
          optional(:status) => atom(),
          optional(:error) => term(),
          optional(:reason) => term()
        }

  @doc "Build a pipeline_started event."
  def pipeline_started(graph_id, opts \\ []) do
    %{type: :pipeline_started, graph_id: graph_id}
    |> Map.merge(Map.new(opts))
  end

  @doc "Build a pipeline_completed event."
  def pipeline_completed(completed_nodes) do
    %{type: :pipeline_completed, completed_nodes: completed_nodes}
  end

  @doc "Build a pipeline_failed event."
  def pipeline_failed(reason) do
    %{type: :pipeline_failed, reason: reason}
  end

  @doc "Build a stage_started event."
  def stage_started(node_id) do
    %{type: :stage_started, node_id: node_id}
  end

  @doc "Build a stage_completed event."
  def stage_completed(node_id, status) do
    %{type: :stage_completed, node_id: node_id, status: status}
  end

  @doc "Build a stage_failed event."
  def stage_failed(node_id, error, opts \\ []) do
    %{type: :stage_failed, node_id: node_id, error: error}
    |> Map.merge(Map.new(opts))
  end

  @doc "Build a stage_retrying event."
  def stage_retrying(node_id, attempt, delay_ms) do
    %{type: :stage_retrying, node_id: node_id, attempt: attempt, delay_ms: delay_ms}
  end
end
