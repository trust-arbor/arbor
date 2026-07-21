defmodule Mix.Tasks.Arbor.Coding.Branches do
  @shortdoc "Audit or explicitly apply a reviewed coding-branch manifest"

  @moduledoc """
  Audits local coding branches without mutation, or explicitly settles one
  previously reviewed manifest.

      mix arbor.coding.branches --repo /path/to/repo --destination main \
        --output /tmp/branch-audit.json

      mix arbor.coding.branches --apply /tmp/branch-audit.json \
        --sha256 REVIEWED_DIGEST

  Audit output defaults to stdout. `--output` writes a new file without
  replacing an existing path, which keeps compiler and startup messages out of
  the machine-readable manifest. Add `--checkpoint PATH` to resume a dry-run:
  cached successful proofs are progress hints and are live-revalidated under
  the normal proof budget. Only exact-scope deterministic preserve outcomes are
  reused without proof work. Transient failures are retried on the next run.
  With `--output`, the checkpoint defaults to `OUTPUT.checkpoint`.
  """

  use Mix.Task

  alias Arbor.Actions

  @switches [
    repo: :string,
    destination: :string,
    output: :string,
    checkpoint: :string,
    apply: :string,
    sha256: :string
  ]

  @impl true
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      invalid != [] ->
        Mix.raise("invalid options: #{inspect(invalid)}")

      positional != [] ->
        Mix.raise("unexpected arguments: #{inspect(positional)}")

      is_binary(opts[:apply]) and is_binary(opts[:output]) ->
        Mix.raise("--output is only valid when generating an audit manifest")

      is_binary(opts[:apply]) and is_binary(opts[:checkpoint]) ->
        Mix.raise("--checkpoint is only valid when generating an audit manifest")

      is_binary(opts[:apply]) ->
        with_shell_runtime(fn -> apply_manifest(opts) end)

      is_binary(opts[:sha256]) ->
        Mix.raise("--sha256 requires --apply PATH")

      true ->
        with_shell_runtime(fn -> audit(opts) end)
    end
  end

  defp with_shell_runtime(operation) when is_function(operation, 0) do
    case Arbor.Shell.start_direct_runtime() do
      {:ok, :already_started} ->
        operation.()

      {:ok, supervisor} when is_pid(supervisor) ->
        try do
          operation.()
        after
          if Process.alive?(supervisor), do: Supervisor.stop(supervisor)
        end

      {:error, reason} ->
        Mix.raise("could not start direct shell runtime: #{inspect(reason)}")
    end
  end

  defp audit(opts) do
    repo = opts[:repo] || Mix.raise("--repo is required for audit")
    destination = opts[:destination] || "main"

    checkpoint = opts[:checkpoint] || default_checkpoint(opts[:output])

    audit_opts =
      [
        checkpoint: checkpoint,
        progress: fn snapshot ->
          Mix.shell().error("branch audit progress: " <> Jason.encode!(snapshot))
        end
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case Actions.audit_coding_branches(repo, destination, audit_opts) do
      {:ok, manifest} ->
        {:ok, json} = Actions.encode_coding_branch_manifest(manifest)
        emit_audit(json, opts[:output])

      {:error, reason} ->
        Mix.raise("coding branch audit failed: #{inspect(reason)}")
    end
  end

  defp emit_audit(json, nil), do: Mix.shell().info(json)

  defp emit_audit(json, path) when is_binary(path) and byte_size(path) > 0 do
    case File.write(path, json <> "\n", [:binary, :exclusive]) do
      :ok -> Mix.shell().info("wrote branch audit manifest to #{path}")
      {:error, reason} -> Mix.raise("could not write branch audit manifest: #{inspect(reason)}")
    end
  end

  defp emit_audit(_json, _path), do: Mix.raise("--output must name a non-empty path")

  defp default_checkpoint(path) when is_binary(path) and byte_size(path) > 0,
    do: path <> ".checkpoint"

  defp default_checkpoint(_path), do: nil

  defp apply_manifest(opts) do
    path = opts[:apply]
    expected_sha256 = opts[:sha256] || Mix.raise("--sha256 is required with --apply")

    with {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular,
         true <- stat.size <= 32 * 1024 * 1024,
         {:ok, bytes} <- File.read(path),
         {:ok, manifest} <- Actions.decode_coding_branch_manifest(bytes),
         {:ok, report} <- Actions.settle_coding_branches(manifest, expected_sha256) do
      {:ok, json} = Jason.encode(report)
      Mix.shell().info(json)
    else
      false -> Mix.raise("reviewed manifest is not a bounded regular file")
      {:error, reason} -> Mix.raise("reviewed branch manifest apply failed: #{inspect(reason)}")
    end
  end
end
