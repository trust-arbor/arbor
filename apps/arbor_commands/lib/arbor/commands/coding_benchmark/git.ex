defmodule Arbor.Commands.CodingBenchmark.Git do
  @moduledoc false

  @max_output_bytes 65_536

  @spec run(String.t(), [String.t()], pos_integer()) :: {:ok, String.t()} | {:error, String.t()}
  def run(workdir, args, timeout_ms)
      when is_binary(workdir) and is_list(args) and is_integer(timeout_ms) and timeout_ms > 0 do
    case Arbor.Shell.execute_direct("git", ["-C", workdir | args],
           sandbox: :none,
           timeout: timeout_ms,
           max_output_bytes: @max_output_bytes
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

  def run(_workdir, _args, _timeout_ms), do: {:error, "git_invalid_request"}

  defp bounded_output(output) when is_binary(output) do
    output
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, 500)
  end

  defp bounded_output(output),
    do: output |> inspect(limit: 20, printable_limit: 500) |> String.slice(0, 500)
end
