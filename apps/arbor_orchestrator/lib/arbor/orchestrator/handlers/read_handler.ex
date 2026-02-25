defmodule Arbor.Orchestrator.Handlers.ReadHandler do
  @moduledoc """
  Core handler for read operations — files and pipeline context.

  Canonical type: `read`

  Dispatches by `source` attribute:
    - `"file"` (default) — reads a file from the filesystem
    - `"context"` — reads from pipeline context (identity)

  ## Node Attributes

    - `source` — read source: "file" (default), "context"
    - `source_key` — context key or file path to read from
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Context, Outcome}

  @impl true
  def execute(node, context, _graph, opts) do
    source = Map.get(node.attrs, "source", "file")

    case source do
      "file" ->
        read_file(node, context, opts)

      "context" ->
        read_context(node, context)

      _ ->
        read_file(node, context, opts)
    end
  end

  @impl true
  def idempotency, do: :read_only

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
end
