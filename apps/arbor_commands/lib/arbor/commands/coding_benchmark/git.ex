defmodule Arbor.Commands.CodingBenchmark.Git do
  @moduledoc false

  @max_output_bytes 65_536
  @max_configured_output_bytes 268_435_456
  @neutral_config [
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "core.fsmonitor=false",
    "-c",
    "core.pager=cat",
    "-c",
    "pager.status=false",
    "-c",
    "commit.gpgSign=false"
  ]

  @spec run(String.t(), [String.t()], pos_integer(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def run(workdir, args, timeout_ms, opts \\ [])

  def run(workdir, args, timeout_ms, opts)
      when is_binary(workdir) and is_list(args) and is_integer(timeout_ms) and timeout_ms > 0 do
    max_output_bytes = Keyword.get(opts, :max_output_bytes, @max_output_bytes)

    with true <-
           is_integer(max_output_bytes) and max_output_bytes > 0 and
             max_output_bytes <= @max_configured_output_bytes do
      execute(
        ["--no-replace-objects", "-C", workdir] ++ @neutral_config ++ args,
        timeout_ms,
        max_output_bytes
      )
    else
      _other -> {:error, "git_invalid_request"}
    end
  end

  def run(_workdir, _args, _timeout_ms, _opts), do: {:error, "git_invalid_request"}

  defp execute(args, timeout_ms, max_output_bytes) do
    case Arbor.Shell.execute_direct("git", args,
           sandbox: :none,
           timeout: timeout_ms,
           max_output_bytes: max_output_bytes,
           env: %{"GIT_NO_REPLACE_OBJECTS" => "1"}
         ) do
      {:ok, %{timed_out: true}} ->
        {:error, "git_timeout:#{timeout_ms}"}

      {:ok, %{output_limit_exceeded: true, stdout: output}} ->
        {:error, "git_output_limit:#{bounded_output(output)}"}

      {:ok, %{exit_code: 0, stdout: output}} ->
        {:ok, output}

      {:ok, %{exit_code: status, stdout: output}} ->
        {:error, "git_failed:#{status}:#{bounded_output(output)}"}

      {:error, reason} ->
        {:error, "git_execution_failed:#{bounded_output(inspect(reason))}"}
    end
  catch
    :exit, reason -> {:error, "git_shell_unavailable:#{bounded_output(inspect(reason))}"}
  end

  defp bounded_output(output) when is_binary(output) do
    output
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, 500)
  end

  defp bounded_output(output),
    do: output |> inspect(limit: 20, printable_limit: 500) |> String.slice(0, 500)
end
