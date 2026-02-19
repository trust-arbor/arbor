defmodule Arbor.Orchestrator.Handlers.WriteHandler do
  @moduledoc """
  Core handler for write operations — memory, files, accumulators.

  Canonical type: `write`
  Aliases: `file.write`, `memory.consolidate`, `memory.index`,
           `memory.working_save`, `memory.store_file`, `accumulator`,
           `eval.persist`, `eval.report`

  Dispatches by `target` attribute:
    - `"memory"` (default) — delegates to MemoryHandler with appropriate op
    - `"file"` — delegates to FileWriteHandler
    - `"accumulator"` — delegates to AccumulatorHandler
    - `"eval"` — delegates to EvalPersistHandler or EvalReportHandler

  ## Node Attributes

    - `target` — write target: "memory" (default), "file", "accumulator", "eval"
    - `op` — memory operation: "consolidate", "index", "working_save", "store_file"
    - `mode` — write mode: "overwrite" (default), "append"
    - All attributes from the delegated handler are supported
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.Outcome
  alias Arbor.Orchestrator.Handlers.{AccumulatorHandler, FileWriteHandler, MemoryHandler}

  @impl true
  def execute(node, context, graph, opts) do
    target = Map.get(node.attrs, "target", "memory")

    case target do
      "memory" ->
        op = Map.get(node.attrs, "op", "working_save")
        dispatch_memory_write(op, node, context, graph, opts)

      "file" ->
        FileWriteHandler.execute(node, context, graph, opts)

      "accumulator" ->
        AccumulatorHandler.execute(node, context, graph, opts)

      "eval" ->
        op = Map.get(node.attrs, "op", "persist")
        delegate_eval(op, node, context, graph, opts)

      _ ->
        MemoryHandler.execute(node, context, graph, opts)
    end
  end

  @impl true
  def idempotency, do: :side_effecting

  # Specialized memory operations dispatch to their own handlers
  defp dispatch_memory_write("store_file", node, context, graph, opts) do
    delegate_to(Arbor.Orchestrator.Handlers.MemoryStoreHandler, node, context, graph, opts)
  end

  defp dispatch_memory_write(op, node, context, graph, opts) do
    # Standard memory ops go through MemoryHandler
    memory_type = "memory.#{op}"
    node_with_type = %{node | attrs: Map.put(node.attrs, "type", memory_type)}
    MemoryHandler.execute(node_with_type, context, graph, opts)
  end

  defp delegate_eval("persist", node, context, graph, opts) do
    delegate_to(Arbor.Orchestrator.Handlers.EvalPersistHandler, node, context, graph, opts)
  end

  defp delegate_eval("report", node, context, graph, opts) do
    delegate_to(Arbor.Orchestrator.Handlers.EvalReportHandler, node, context, graph, opts)
  end

  defp delegate_eval(unknown, node, _context, _graph, _opts) do
    %Outcome{
      status: :fail,
      failure_reason: "Unknown eval write op '#{unknown}' for node #{node.id}"
    }
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
end
