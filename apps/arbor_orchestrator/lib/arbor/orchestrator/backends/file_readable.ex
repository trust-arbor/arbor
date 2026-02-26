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

  alias Arbor.Contracts.Handler.ScopedContext

  @impl true
  def read(%ScopedContext{} = ctx, opts) do
    path = ScopedContext.get(ctx, "source_key") || ScopedContext.get(ctx, "path")

    unless path do
      {:error, :missing_path}
    else
      workdir =
        ScopedContext.get(ctx, "workdir") ||
          Keyword.get(opts, :workdir, ".")

      resolved =
        if Path.type(path) == :absolute, do: path, else: Path.join(workdir, path)

      case File.read(Path.expand(resolved)) do
        {:ok, content} ->
          {:ok, content}

        {:error, reason} ->
          {:error, {:file_error, reason, resolved}}
      end
    end
  end

  @impl true
  def list(%ScopedContext{} = ctx, opts) do
    path = ScopedContext.get(ctx, "source_key") || ScopedContext.get(ctx, "path")

    unless path do
      {:error, :missing_path}
    else
      workdir =
        ScopedContext.get(ctx, "workdir") ||
          Keyword.get(opts, :workdir, ".")

      resolved =
        if Path.type(path) == :absolute, do: path, else: Path.join(workdir, path)

      expanded = Path.expand(resolved)

      case File.ls(expanded) do
        {:ok, files} -> {:ok, files}
        {:error, reason} -> {:error, {:file_error, reason, expanded}}
      end
    end
  end

  @impl true
  def capability_required(_operation, _ctx) do
    "arbor://handler/read/file"
  end
end
