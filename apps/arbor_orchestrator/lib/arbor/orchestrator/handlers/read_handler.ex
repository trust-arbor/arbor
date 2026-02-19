defmodule Arbor.Orchestrator.Handlers.ReadHandler do
  @moduledoc """
  Core handler for read operations — memory, files, ETS, databases.

  Canonical type: `read`
  Aliases: `memory.recall`, `memory.working_load`, `memory.stats`,
           `memory.recall_store`, `eval.dataset`

  Dispatches by `source` attribute:
    - `"memory"` (default) — delegates to MemoryHandler with appropriate op
    - `"eval_dataset"` — delegates to EvalDatasetHandler
    - `"file"` — reads a file from the filesystem
    - `"context"` — reads from pipeline context (identity)

  ## Node Attributes

    - `source` — read source: "memory" (default), "eval_dataset", "file", "context"
    - `op` — memory operation: "recall", "working_load", "stats", "recall_store"
    - `source_key` — context key or file path to read from
    - All attributes from the delegated handler are supported
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Handlers.MemoryHandler

  @impl true
  def execute(node, context, graph, opts) do
    source = Map.get(node.attrs, "source", "memory")

    case source do
      "memory" ->
        op = Map.get(node.attrs, "op", "recall")
        dispatch_memory_read(op, node, context, graph, opts)

      "eval_dataset" ->
        delegate_to(
          Arbor.Orchestrator.Handlers.EvalDatasetHandler,
          node,
          context,
          graph,
          opts
        )

      "file" ->
        read_file(node, context, opts)

      "context" ->
        read_context(node, context)

      _ ->
        MemoryHandler.execute(node, context, graph, opts)
    end
  end

  @impl true
  def idempotency, do: :read_only

  # Specialized memory operations dispatch to their own handlers
  defp dispatch_memory_read("recall_store", node, context, graph, opts) do
    delegate_to(
      Arbor.Orchestrator.Handlers.MemoryRecallHandler,
      node,
      context,
      graph,
      opts
    )
  end

  defp dispatch_memory_read(op, node, context, graph, opts) do
    # Standard memory ops go through MemoryHandler
    memory_type = "memory.#{op}"
    node_with_type = %{node | attrs: Map.put(node.attrs, "type", memory_type)}
    MemoryHandler.execute(node_with_type, context, graph, opts)
  end

  defp read_file(node, context, opts) do
    path = Map.get(node.attrs, "source_key") || Map.get(node.attrs, "path")

    unless path do
      raise "read with source=file requires 'path' or 'source_key' attribute"
    end

    workdir = Context.get(context, "workdir") || Keyword.get(opts, :workdir, ".")

    resolved =
      if Path.type(path) == :absolute, do: path, else: Path.join(workdir, path)

    case File.read(Path.expand(resolved)) do
      {:ok, content} ->
        output_key = Map.get(node.attrs, "output_key", "read.#{node.id}")

        %Outcome{
          status: :success,
          notes: "Read #{byte_size(content)} bytes from #{resolved}",
          context_updates: %{
            output_key => content,
            "last_response" => content
          }
        }

      {:error, reason} ->
        %Outcome{
          status: :fail,
          failure_reason: "File read error: #{inspect(reason)} for #{resolved}"
        }
    end
  end

  defp read_context(node, context) do
    source_key = Map.get(node.attrs, "source_key", "last_response")
    output_key = Map.get(node.attrs, "output_key", "read.#{node.id}")
    value = Context.get(context, source_key)

    %Outcome{
      status: :success,
      notes: "Read context key #{source_key}",
      context_updates: %{output_key => value}
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
