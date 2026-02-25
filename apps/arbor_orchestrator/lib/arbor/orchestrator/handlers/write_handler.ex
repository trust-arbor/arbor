defmodule Arbor.Orchestrator.Handlers.WriteHandler do
  @moduledoc """
  Core handler for write operations — files and accumulators.

  Canonical type: `write`
  Aliases: `file.write`, `accumulator`

  Dispatches by `target` attribute:
    - `"file"` (default) — delegates to FileWriteHandler
    - `"accumulator"` — delegates to AccumulatorHandler

  ## Node Attributes

    - `target` — write target: "file" (default), "accumulator"
    - `mode` — write mode: "overwrite" (default), "append"
    - All attributes from the delegated handler are supported
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Handlers.{AccumulatorHandler, FileWriteHandler}

  @impl true
  def execute(node, context, graph, opts) do
    target = Map.get(node.attrs, "target", "file")

    case target do
      "file" ->
        FileWriteHandler.execute(node, context, graph, opts)

      "accumulator" ->
        AccumulatorHandler.execute(node, context, graph, opts)

      _ ->
        FileWriteHandler.execute(node, context, graph, opts)
    end
  end

  @impl true
  def idempotency, do: :side_effecting
end
