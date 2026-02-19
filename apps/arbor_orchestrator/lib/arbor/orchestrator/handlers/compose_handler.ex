defmodule Arbor.Orchestrator.Handlers.ComposeHandler do
  @moduledoc """
  Core handler for graph composition — subgraphs, pipelines, feedback loops.

  Canonical type: `compose`
  Aliases: `graph.invoke`, `graph.compose`, `pipeline.run`, `feedback.loop`,
           `stack.manager_loop`, `consensus.*`, `session.*`

  Dispatches by `mode` attribute:
    - `"invoke"` (default) — delegates to SubgraphHandler (graph.invoke)
    - `"compose"` — delegates to SubgraphHandler (graph.compose)
    - `"pipeline"` — delegates to PipelineRunHandler
    - `"feedback"` — delegates to FeedbackLoopHandler
    - `"manager_loop"` — delegates to ManagerLoopHandler
    - `"consensus"` — delegates to ConsensusHandler (consensus.*)
    - `"session"` — delegates to SessionHandler (session.*)

  ## Node Attributes

    - `mode` — composition mode: "invoke" (default), "compose", "pipeline",
      "feedback", "manager_loop", "consensus", "session"
    - All attributes from the delegated handler are supported
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.Outcome

  alias Arbor.Orchestrator.Handlers.{
    FeedbackLoopHandler,
    ManagerLoopHandler,
    PipelineRunHandler,
    SubgraphHandler
  }

  @impl true
  def execute(node, context, graph, opts) do
    mode = Map.get(node.attrs, "mode", "invoke")

    case mode do
      "invoke" ->
        SubgraphHandler.execute(node, context, graph, opts)

      "compose" ->
        SubgraphHandler.execute(node, context, graph, opts)

      "pipeline" ->
        PipelineRunHandler.execute(node, context, graph, opts)

      "feedback" ->
        FeedbackLoopHandler.execute(node, context, graph, opts)

      "manager_loop" ->
        ManagerLoopHandler.execute(node, context, graph, opts)

      "consensus" ->
        delegate_to(Arbor.Orchestrator.Handlers.ConsensusHandler, node, context, graph, opts)

      "session" ->
        delegate_to(Arbor.Orchestrator.Handlers.SessionHandler, node, context, graph, opts)

      _ ->
        SubgraphHandler.execute(node, context, graph, opts)
    end
  end

  @impl true
  def idempotency, do: :side_effecting

  defp delegate_to(module, node, context, graph, opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :execute, 4) do
      module.execute(node, context, graph, opts)
    else
      %Outcome{
        status: :fail,
        failure_reason: "Handler module #{inspect(module)} not available"
      }
    end
  end
end
