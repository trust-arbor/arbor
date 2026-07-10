defmodule Arbor.Orchestrator.Handlers.ComposeHandler do
  @moduledoc """
  Core handler for graph composition — subgraphs, pipelines, loops.

  Canonical type: `compose`
  Aliases: `graph.invoke`, `graph.compose`, `pipeline.run`,
           `stack.manager_loop`

  Dispatches by `mode` attribute via PipelineResolver. Falls back to
  inline implementation when the registry is unavailable.

    - `"invoke"` (default) — delegates to SubgraphHandler (graph.invoke)
    - `"compose"` — delegates to SubgraphHandler (graph.compose)
    - `"pipeline"` — delegates to PipelineRunHandler
    - `"manager_loop"` — delegates to ManagerLoopHandler

  Consensus operations are now Jido actions in `Arbor.Actions.Consensus`,
  invoked via `exec target="action" action="consensus.*"` in DOT pipelines.

  Session operations are now Jido actions in `Arbor.Actions.Session*`,
  invoked via `exec target="action"` + `compute` nodes in DOT pipelines.

  ## Node Attributes

    - `mode` — composition mode: "invoke" (default), "compose", "pipeline",
      "manager_loop"
    - All attributes from the delegated handler are supported
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Outcome, RunAuthorization}

  alias Arbor.Orchestrator.Handlers.{
    ManagerLoopHandler,
    PipelineRunHandler,
    SubgraphHandler
  }

  @impl true
  def execute(node, context, graph, opts) do
    with {:ok, [{slot, handler_module}]} <- execution_delegates(node),
         :ok <- verify_delegate(node, slot, handler_module, opts) do
      safe_execute(handler_module, node, context, graph, opts)
    else
      {:error, reason} -> binding_failure(node, reason)
      _other -> binding_failure(node, :invalid_compose_delegate)
    end
  end

  @impl true
  def idempotency, do: :side_effecting

  @doc false
  def execution_delegates(node) do
    mode = Map.get(node.attrs, "mode", "invoke")

    module =
      case registry_resolve(mode) do
        {:ok, handler_module} -> handler_module
        {:error, _reason} -> legacy_delegate(mode)
      end

    if is_atom(module) do
      {:ok, [{"compose:#{mode}", module}]}
    else
      {:error, {:invalid_compose_mode, mode}}
    end
  end

  defp legacy_delegate("invoke"), do: SubgraphHandler
  defp legacy_delegate("compose"), do: SubgraphHandler
  defp legacy_delegate("pipeline"), do: PipelineRunHandler
  defp legacy_delegate("manager_loop"), do: ManagerLoopHandler
  defp legacy_delegate(_unknown), do: SubgraphHandler

  defp safe_execute(module, node, context, graph, opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :execute, 4) do
      module.execute(node, context, graph, opts)
    else
      %Outcome{
        status: :fail,
        failure_reason: "Handler module #{inspect(module)} does not implement execute/4"
      }
    end
  end

  defp verify_delegate(node, slot, module, opts) do
    RunAuthorization.verify_execution_module(
      Keyword.get(opts, :run_authorization),
      node,
      slot,
      module
    )
  end

  defp binding_failure(node, reason) do
    %Outcome{
      status: :fail,
      failure_reason: "Compose delegate binding rejected for node #{node.id}: #{inspect(reason)}"
    }
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
