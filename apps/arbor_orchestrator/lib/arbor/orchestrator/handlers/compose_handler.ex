defmodule Arbor.Orchestrator.Handlers.ComposeHandler do
  @moduledoc """
  Core handler for graph composition — subgraphs, pipelines, loops.

  Canonical type: `compose`
  Aliases: `graph.invoke`, `graph.compose`, `pipeline.run`,
           `stack.manager_loop`, `session.*`

  Dispatches by `mode` attribute via PipelineResolver. Falls back to
  inline implementation when the registry is unavailable.

    - `"invoke"` (default) — delegates to SubgraphHandler (graph.invoke)
    - `"compose"` — delegates to SubgraphHandler (graph.compose)
    - `"pipeline"` — delegates to PipelineRunHandler
    - `"manager_loop"` — delegates to ManagerLoopHandler
    - `"session"` — delegates to SessionHandler (session.*)

  Consensus operations are now Jido actions in `Arbor.Actions.Consensus`,
  invoked via `exec target="action" action="consensus.*"` in DOT pipelines.

  ## Node Attributes

    - `mode` — composition mode: "invoke" (default), "compose", "pipeline",
      "manager_loop", "session"
    - All attributes from the delegated handler are supported
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.Outcome

  alias Arbor.Orchestrator.Handlers.{
    ManagerLoopHandler,
    PipelineRunHandler,
    SubgraphHandler
  }

  @impl true
  def execute(node, context, graph, opts) do
    mode = Map.get(node.attrs, "mode", "invoke")

    case registry_resolve(mode) do
      {:ok, handler_module} ->
        safe_execute(handler_module, node, context, graph, opts)

      {:error, _} ->
        legacy_dispatch(mode, node, context, graph, opts)
    end
  end

  @impl true
  def idempotency, do: :side_effecting

  # Legacy inline dispatch — used when registry is unavailable.
  defp legacy_dispatch(mode, node, context, graph, opts) do
    case mode do
      "invoke" ->
        SubgraphHandler.execute(node, context, graph, opts)

      "compose" ->
        SubgraphHandler.execute(node, context, graph, opts)

      "pipeline" ->
        PipelineRunHandler.execute(node, context, graph, opts)

      "manager_loop" ->
        ManagerLoopHandler.execute(node, context, graph, opts)

      "session" ->
        delegate_to(Arbor.Orchestrator.Handlers.SessionHandler, node, context, graph, opts)

      _ ->
        SubgraphHandler.execute(node, context, graph, opts)
    end
  end

  defp safe_execute(module, node, context, graph, opts) do
    if function_exported?(module, :execute, 4) do
      module.execute(node, context, graph, opts)
    else
      %Outcome{
        status: :fail,
        failure_reason: "Handler module #{inspect(module)} does not implement execute/4"
      }
    end
  end

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

  defp registry_resolve(mode) do
    registry = Arbor.Common.PipelineResolver

    if Process.whereis(registry) do
      registry.resolve_stable(mode)
    else
      {:error, :registry_unavailable}
    end
  end
end
