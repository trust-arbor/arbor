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
  @neutral_env %{
    "GIT_CONFIG_GLOBAL" => "/dev/null",
    "GIT_CONFIG_NOSYSTEM" => "1",
    "GIT_NO_LAZY_FETCH" => "1",
    "GIT_NO_REPLACE_OBJECTS" => "1",
    "GIT_TERMINAL_PROMPT" => "0",
    "LC_ALL" => "C"
  }

  @type timeout_spec :: pos_integer() | {:deadline, integer()}

  @doc false
  @spec deadline(pos_integer()) :: {:deadline, integer()}
  def deadline(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    {:deadline, System.monotonic_time(:millisecond) + timeout_ms}
  end

  @spec run(String.t(), [String.t()], timeout_spec(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def run(workdir, args, timeout_ms, opts \\ [])

  def run(workdir, args, timeout, opts) when is_binary(workdir) and is_list(args) do
    max_output_bytes = Keyword.get(opts, :max_output_bytes, @max_output_bytes)

    with {:ok, timeout_ms} <- remaining_timeout(timeout),
         true <-
           is_integer(max_output_bytes) and max_output_bytes > 0 and
             max_output_bytes <= @max_configured_output_bytes do
      execute(
        ["--no-replace-objects", "-C", workdir] ++ @neutral_config ++ args,
        timeout_ms,
        max_output_bytes
      )
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _other -> {:error, "git_invalid_request"}
    end
  end

  def run(_workdir, _args, _timeout_ms, _opts), do: {:error, "git_invalid_request"}

  defp remaining_timeout(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0,
    do: {:ok, timeout_ms}

  defp remaining_timeout({:deadline, deadline}) when is_integer(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> {:ok, remaining}
      _expired -> {:error, "git_timeout:deadline_exceeded"}
    end
  end

  defp remaining_timeout(_timeout), do: {:error, "git_invalid_request"}

  defp execute(args, timeout_ms, max_output_bytes) do
    case Arbor.Shell.execute_direct("git", args,
           sandbox: :none,
           timeout: timeout_ms,
           max_output_bytes: max_output_bytes,
           clear_env: true,
           env: @neutral_env
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
