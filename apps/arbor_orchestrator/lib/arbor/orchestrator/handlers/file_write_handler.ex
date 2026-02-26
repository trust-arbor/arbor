defmodule Arbor.Orchestrator.Handlers.FileWriteHandler do
  @moduledoc """
  Handler that writes context data to a file.

  Node attributes:
    - `content_key` - context key whose value to write (required)
    - `output` - file path to write to (required, resolved relative to workdir)
    - `format` - output format: "raw" (default), "json", "text"
    - `append` - "true" to append instead of overwrite (default: false)
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Common.SafePath
  alias Arbor.Orchestrator.Engine.{Context, Outcome}

  @impl true
  def execute(node, context, _graph, opts) do
    content_key = Map.get(node.attrs, "content_key")
    output_path = Map.get(node.attrs, "output")

    unless content_key do
      raise "file.write requires 'content_key' attribute"
    end

    unless output_path do
      raise "file.write requires 'output' attribute"
    end

    value = Context.get(context, content_key)

    unless value do
      raise "context key '#{content_key}' not found"
    end

    format = Map.get(node.attrs, "format", "raw")
    append = Map.get(node.attrs, "append") in ["true", true]

    workdir = Context.get(context, "workdir") || Keyword.get(opts, :workdir, ".")

    case resolve_path(output_path, workdir) do
      {:ok, resolved_path} ->
        content = format_content(value, format)

        File.mkdir_p!(Path.dirname(resolved_path))

        if append do
          File.write!(resolved_path, content, [:append])
        else
          File.write!(resolved_path, content)
        end

        %Outcome{
          status: :success,
          notes: "Wrote #{byte_size(content)} bytes to #{resolved_path}",
          context_updates: %{"file.written.#{node.id}" => resolved_path}
        }

      {:error, :path_traversal} ->
        %Outcome{
          status: :fail,
          failure_reason: "path traversal blocked: #{output_path} escapes workdir #{workdir}"
        }
    end
  rescue
    e ->
      %Outcome{
        status: :fail,
        failure_reason: "file.write error: #{Exception.message(e)}"
      }
  end

  @impl true
  def idempotency, do: :idempotent_with_key

  defp resolve_path(path, workdir) do
    SafePath.resolve_within(path, Path.expand(workdir))
  end

  defp format_content(value, "json") do
    case Jason.encode(value, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> Jason.encode!(to_string(value))
    end
  end

  defp format_content(value, _format) do
    to_string(value)
  end
end
