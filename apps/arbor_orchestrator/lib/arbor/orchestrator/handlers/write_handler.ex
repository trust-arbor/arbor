defmodule Arbor.Orchestrator.Handlers.WriteHandler do
  @moduledoc """
  Core handler for write operations — files and accumulators.

  Canonical type: `write`
  Aliases: `file.write`, `accumulator`

  Dispatches by `target` attribute via WriteableRegistry. Falls back to
  inline implementation when the registry is unavailable.

    - `"file"` (default) — delegates to FileWriteHandler
    - `"accumulator"` — delegates to AccumulatorHandler

  ## Node Attributes

    - `target` — write target: "file" (default), "accumulator"
    - `mode` — write mode: "overwrite" (default), "append"
    - All attributes from the delegated handler are supported
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Outcome, RunAuthorization}
  alias Arbor.Orchestrator.Handlers.{AccumulatorHandler, FileWriteHandler}

  @impl true
  def execute(node, context, graph, opts) do
    with {:ok, [{slot, handler_module}]} <- execution_delegates(node),
         :ok <-
           RunAuthorization.verify_execution_module(
             Keyword.get(opts, :run_authorization),
             node,
             slot,
             handler_module
           ) do
      if Code.ensure_loaded?(handler_module) and function_exported?(handler_module, :execute, 4) do
        handler_module.execute(node, context, graph, opts)
      else
        %Outcome{status: :fail, failure_reason: "Write delegate is unavailable"}
      end
    else
      {:error, reason} ->
        %Outcome{
          status: :fail,
          failure_reason:
            "Write delegate binding rejected for node #{node.id}: #{inspect(reason)}"
        }
    end
  end

  @impl true
  def idempotency, do: :side_effecting

  @doc false
  def execution_delegates(node) do
    target = Map.get(node.attrs, "target", "file")

    module =
      case registry_resolve(target) do
        {:ok, handler_module} -> handler_module
        {:error, _reason} -> legacy_delegate(target)
      end

    if is_atom(module) do
      {:ok, [{"write:#{target}", module}]}
    else
      {:error, {:invalid_write_target, target}}
    end
  end

  defp legacy_delegate("accumulator"), do: AccumulatorHandler
  defp legacy_delegate(_target), do: FileWriteHandler

  defp registry_resolve(target) do
    registry = Arbor.Common.WriteableRegistry

    if Process.whereis(registry) do
      registry.resolve_stable(target)
    else
      {:error, :registry_unavailable}
    end
  end
end
