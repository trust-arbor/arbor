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

  For consensus.* and session.* types, nodes retain their original type
  attribute and are dispatched to their respective specialized handlers
  via the compat layer. This handler is the canonical entry point for
  new composition operations.

  ## Node Attributes

    - `mode` — composition mode: "invoke" (default), "compose", "pipeline",
      "feedback", "manager_loop"
    - All attributes from the delegated handler are supported
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

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
      "invoke" -> SubgraphHandler.execute(node, context, graph, opts)
      "compose" -> SubgraphHandler.execute(node, context, graph, opts)
      "pipeline" -> PipelineRunHandler.execute(node, context, graph, opts)
      "feedback" -> FeedbackLoopHandler.execute(node, context, graph, opts)
      "manager_loop" -> ManagerLoopHandler.execute(node, context, graph, opts)
      _ -> SubgraphHandler.execute(node, context, graph, opts)
    end
  end

  @impl true
  def idempotency, do: :side_effecting
end
