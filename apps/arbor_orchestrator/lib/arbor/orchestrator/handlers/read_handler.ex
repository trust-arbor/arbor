defmodule Arbor.Orchestrator.Handlers.ReadHandler do
  @moduledoc """
  Core handler for read operations — files and pipeline context.

  Canonical type: `read`

  Dispatches by `source` attribute via ReadableRegistry. Falls back to
  inline implementation when the registry is unavailable.

    - `"file"` (default) — reads a file from the filesystem
    - `"context"` — reads from pipeline context (identity)

  ## Node Attributes

    - `source` — read source: "file" (default), "context"
    - `source_key` — context key or file path to read from
    - `output_key` — context key to store result (default: "read.{node_id}")
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Contracts.Handler.ScopedContext
  alias Arbor.Orchestrator.Engine.{Context, Outcome}

  @impl true
  def execute(node, context, _graph, opts) do
    source = Map.get(node.attrs, "source", "file")
    dispatch_via_registry(source, node, context, opts)
  end

  @impl true
  def idempotency, do: :read_only

  # Try ReadableRegistry first, fall back to inline implementation.
  defp dispatch_via_registry(source, node, context, opts) do
    case registry_resolve(source) do
      {:ok, readable_module} ->
        execute_readable(readable_module, source, node, context, opts)

      {:error, _} ->
        # Fallback: inline implementation for core sources
        legacy_dispatch(source, node, context, opts)
    end
  end

  # Execute a Readable behaviour module and wrap result in Outcome.
  defp execute_readable(readable_module, source, node, context, opts) do
    workdir = Context.get(context, "workdir") || Keyword.get(opts, :workdir, ".")

    # Merge node attrs into context so Readable modules can access both
    # Node attrs (path, source_key) + context values (arbitrary keys for context reads)
    merged = Map.merge(context_to_map(context), node.attrs)

    scoped =
      ScopedContext.from_node_and_context(
        %{id: node.id, type: "read", attrs: node.attrs},
        merged
      )

    # Ensure workdir is available in scoped context
    scoped =
      if ScopedContext.get(scoped, "workdir") == nil do
        ScopedContext.put(scoped, "workdir", workdir)
      else
        scoped
      end

    case readable_module.read(scoped, opts) do
      {:ok, content} ->
        output_key = Map.get(node.attrs, "output_key", "read.#{node.id}")

        notes =
          if is_binary(content),
            do: "Read #{byte_size(content)} bytes via #{source}",
            else: "Read value via #{source}"

        %Outcome{
          status: :success,
          notes: notes,
          context_updates: %{
            output_key => content,
            "last_response" => content
          }
        }

      {:error, :missing_path} ->
        %Outcome{
          status: :fail,
          failure_reason: "read with source=#{source} requires 'path' or 'source_key' attribute"
        }

      {:error, {:file_error, reason, resolved}} ->
        record_failure(source)

        %Outcome{
          status: :fail,
          failure_reason: "File read error: #{inspect(reason)} for #{resolved}"
        }

      {:error, reason} ->
        record_failure(source)

        %Outcome{
          status: :fail,
          failure_reason: "Read error: #{inspect(reason)}"
        }
    end
  end

  # Legacy inline dispatch — used when registry is unavailable.
  defp legacy_dispatch(source, node, context, opts) do
    case source do
      "file" -> read_file(node, context, opts)
      "context" -> read_context(node, context)
      _ -> read_file(node, context, opts)
    end
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

  # Resolve from ReadableRegistry if running. Uses resolve_stable to skip
  # entries that have exceeded their circuit breaker failure threshold.
  defp registry_resolve(source) do
    registry = Arbor.Common.ReadableRegistry

    if Process.whereis(registry) do
      registry.resolve_stable(source)
    else
      {:error, :registry_unavailable}
    end
  end

  defp record_failure(source) do
    registry = Arbor.Common.ReadableRegistry

    if Process.whereis(registry) do
      registry.record_failure(source)
    end
  end

  # Extract a plain map from the engine Context for ScopedContext construction.
  defp context_to_map(%Context{} = context), do: Context.snapshot(context)
  defp context_to_map(context) when is_map(context), do: context
  defp context_to_map(_context), do: %{}
end
