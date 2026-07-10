defmodule Arbor.Orchestrator.Handlers.ComputeHandler do
  @moduledoc """
  Core handler for computation nodes — LLM calls, routing.

  Canonical type: `compute`
  Aliases: `codergen`, `routing.select`

  Dispatches by `purpose` attribute via ComputeRegistry. Falls back to
  inline implementation when the registry is unavailable.

    - `"llm"` (default) — delegates to LlmHandler
    - `"routing"` — delegates to RoutingHandler

  ## Node Attributes

    - `purpose` — computation purpose (default: "llm")
    - All attributes from the delegated handler are supported
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Outcome, RunAuthorization}
  alias Arbor.Orchestrator.Handlers.LlmHandler

  @impl true
  def execute(node, context, graph, opts) do
    with {:ok, [{slot, handler_module}]} <- execution_delegates(node),
         :ok <- verify_delegate(node, slot, handler_module, opts) do
      safe_execute(handler_module, node, context, graph, opts)
    else
      {:error, reason} -> binding_failure(node, reason)
      _other -> binding_failure(node, :invalid_compute_delegate)
    end
  end

  @impl true
  def idempotency, do: :idempotent_with_key

  @doc false
  def execution_delegates(node) do
    purpose = Map.get(node.attrs, "purpose", "llm")

    module_result =
      case registry_resolve(purpose) do
        {:ok, handler_module} -> {:ok, handler_module}
        {:error, _reason} -> legacy_delegate(purpose)
      end

    case module_result do
      {:ok, handler_module} -> {:ok, [{"compute:#{purpose}", handler_module}]}
      {:error, _reason} = error -> error
    end
  end

  defp legacy_delegate("llm"), do: {:ok, LlmHandler}

  defp legacy_delegate("routing"),
    do: {:ok, Arbor.Orchestrator.Handlers.RoutingHandler}

  defp legacy_delegate(unknown), do: {:error, {:unknown_compute_purpose, unknown}}

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
      failure_reason: "Compute delegate binding rejected for node #{node.id}: #{inspect(reason)}"
    }
  end

  defp registry_resolve(purpose) do
    registry = Arbor.Common.ComputeRegistry

    if Process.whereis(registry) do
      registry.resolve_stable(purpose)
    else
      {:error, :registry_unavailable}
    end
  end
end
