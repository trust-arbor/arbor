defmodule Arbor.Orchestrator.Handlers.ComputeHandler do
  @moduledoc """
  Core handler for computation nodes — LLM calls, routing.

  Canonical type: `compute`
  Aliases: `codergen`, `routing.select`

  Dispatches by `purpose` attribute via ComputeRegistry. Falls back to
  inline implementation when the registry is unavailable.

    - `"llm"` (default) — delegates to CodergenHandler
    - `"routing"` — delegates to RoutingHandler

  ## Node Attributes

    - `purpose` — computation purpose (default: "llm")
    - All attributes from the delegated handler are supported
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.Outcome
  alias Arbor.Orchestrator.Handlers.CodergenHandler

  @impl true
  def execute(node, context, graph, opts) do
    purpose = Map.get(node.attrs, "purpose", "llm")

    case registry_resolve(purpose) do
      {:ok, handler_module} ->
        safe_execute(handler_module, node, context, graph, opts)

      {:error, _} ->
        legacy_dispatch(purpose, node, context, graph, opts)
    end
  end

  @impl true
  def idempotency, do: :idempotent_with_key

  # Legacy inline dispatch — used when registry is unavailable.
  defp legacy_dispatch(purpose, node, context, graph, opts) do
    case purpose do
      "llm" ->
        CodergenHandler.execute(node, context, graph, opts)

      "routing" ->
        delegate_to(Arbor.Orchestrator.Handlers.RoutingHandler, node, context, graph, opts)

      unknown ->
        %Outcome{
          status: :fail,
          failure_reason: "Unknown compute purpose '#{unknown}' for node #{node.id}"
        }
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

  defp registry_resolve(purpose) do
    if Process.whereis(Arbor.Common.ComputeRegistry) do
      Arbor.Common.ComputeRegistry.resolve(purpose)
    else
      {:error, :registry_unavailable}
    end
  end
end
