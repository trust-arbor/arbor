defmodule Arbor.Orchestrator.Backends.FileReadable do
  @moduledoc """
  Readable implementation for filesystem reads.

  Reads file contents from the local filesystem. Supports absolute paths
  and relative paths resolved against a workdir.

  ## ScopedContext Keys

    - `"source_key"` or `"path"` — the file path to read (required)
    - `"workdir"` — working directory for relative paths (default: ".")
  """

  @behaviour Arbor.Contracts.Handler.Readable

  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Handler.ScopedContext

  @impl true
  def read(%ScopedContext{} = ctx, opts) do
    path = ScopedContext.get(ctx, "source_key") || ScopedContext.get(ctx, "path")

    if path do
      workdir =
        ScopedContext.get(ctx, "workdir") ||
          Keyword.get(opts, :workdir, ".")

      case SafePath.resolve_within(path, Path.expand(workdir)) do
        {:ok, resolved} ->
          case File.read(resolved) do
            {:ok, content} -> {:ok, content}
            {:error, reason} -> {:error, {:file_error, reason, resolved}}
          end

        {:error, :path_traversal} ->
          {:error, {:path_traversal, path, workdir}}
      end
    else
      {:error, :missing_path}
    end
  end

  @impl true
  def list(%ScopedContext{} = ctx, opts) do
    path = ScopedContext.get(ctx, "source_key") || ScopedContext.get(ctx, "path")

    if path do
      workdir =
        ScopedContext.get(ctx, "workdir") ||
          Keyword.get(opts, :workdir, ".")

      case SafePath.resolve_within(path, Path.expand(workdir)) do
        {:ok, resolved} ->
          case File.ls(resolved) do
            {:ok, files} -> {:ok, files}
            {:error, reason} -> {:error, {:file_error, reason, resolved}}
          end

        {:error, :path_traversal} ->
          {:error, {:path_traversal, path, workdir}}
      end
    else
      {:error, :missing_path}
    end
  end

  @impl true
  def capability_required(_operation, _ctx) do
    "arbor://handler/read/file"
  end
end
