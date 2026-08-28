defmodule Arbor.Commands.CodingRun.GitStatus do
  @moduledoc """
  Bounded `git status --porcelain=v1 -z` runner for the coding-run commit gate.

  Output is collected through an Erlang Port. The OS process is killed as soon
  as the 10 s deadline passes or the 1 MiB cap is exceeded. Callers must treat
  any error as fail-closed: never derive an empty path list from a failure.
  """

  @timeout_ms 10_000
  @max_bytes 1_048_576
  @max_paths 2_000
  @kill_grace_ms 200

  @type error_reason ::
          :invalid_worktree
          | :timeout
          | :output_exceeded
          | :path_count_exceeded
          | :nonzero_exit
          | :malformed_output
          | :git_unavailable
          | :port_failed

  @doc """
  Run porcelain status in `worktree`.

  Returns `{:ok, binary}` only on a clean, in-budget, zero-exit capture.
  Decode with `decode/1`. Optional `:executable`, `:args`, `:timeout_ms`, and
  `:max_bytes` are test seams; production callers omit them.
  """
  @spec run(term(), keyword()) :: {:ok, binary()} | {:error, error_reason()}
  def run(worktree, opts \\ [])

  def run(worktree, opts) when is_binary(worktree) and is_list(opts) do
    if valid_worktree?(worktree) do
      collect(worktree, opts)
    else
      {:error, :invalid_worktree}
    end
  end

  def run(_worktree, _opts), do: {:error, :invalid_worktree}

  @doc "Decode a successful porcelain=v1 -z payload into repository-relative paths."
  @spec decode(binary()) ::
          {:ok, [String.t()]} | {:error, :malformed_output | :path_count_exceeded}
  def decode(<<>>), do: {:ok, []}

  # `--porcelain=v1 -z` terminates every record with NUL. A payload without a
  # trailing NUL is truncated or not porcelain at all; it never yields paths
  # (a plausible-looking unterminated record could otherwise authorize the
  # commit gate — council finding, 2026-08-28).
  def decode(binary) when is_binary(binary) do
    if :binary.last(binary) == 0,
      do: walk_records(split_records(binary), [], 0),
      else: {:error, :malformed_output}
  end

  def decode(_binary), do: {:error, :malformed_output}

  defp valid_worktree?(worktree) do
    String.valid?(worktree) and worktree != "" and not String.contains?(worktree, <<0>>) and
      File.dir?(worktree) and git_dir?(worktree)
  end

  defp git_dir?(worktree) do
    git = Path.join(worktree, ".git")
    File.dir?(git) or File.regular?(git)
  end

  defp collect(worktree, opts) do
    executable = Keyword.get(opts, :executable) || System.find_executable("git")
    timeout_ms = Keyword.get(opts, :timeout_ms, @timeout_ms)
    max_bytes = Keyword.get(opts, :max_bytes, @max_bytes)

    args =
      Keyword.get(opts, :args) ||
        ["-C", worktree, "status", "--porcelain=v1", "-z"]

    cond do
      not is_binary(executable) or executable == "" ->
        {:error, :git_unavailable}

      not is_integer(timeout_ms) or timeout_ms < 1 ->
        {:error, :timeout}

      not is_integer(max_bytes) or max_bytes < 1 ->
        {:error, :output_exceeded}

      true ->
        open_and_collect(executable, args, timeout_ms, max_bytes)
    end
  end

  defp open_and_collect(executable, args, timeout_ms, max_bytes) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :hide,
        :use_stdio,
        :stderr_to_stdout,
        {:args, args}
      ])

    os_pid = os_pid(port)
    deadline = monotonic_ms() + timeout_ms

    try do
      await_output(port, os_pid, deadline, max_bytes, <<>>)
    after
      close_port(port)
    end
  rescue
    _error -> {:error, :port_failed}
  catch
    :exit, _reason -> {:error, :port_failed}
  end

  defp await_output(port, os_pid, deadline, max_bytes, acc) do
    remaining = deadline - monotonic_ms()

    if remaining <= 0 do
      kill_os_process(os_pid)
      {:error, :timeout}
    else
      receive do
        {^port, {:data, data}} when is_binary(data) ->
          next = acc <> data

          if byte_size(next) > max_bytes do
            kill_os_process(os_pid)
            {:error, :output_exceeded}
          else
            await_output(port, os_pid, deadline, max_bytes, next)
          end

        {^port, {:exit_status, 0}} ->
          {:ok, acc}

        {^port, {:exit_status, _status}} ->
          {:error, :nonzero_exit}

        {^port, :closed} ->
          {:error, :port_failed}
      after
        remaining ->
          kill_os_process(os_pid)
          drain_port(port)
          {:error, :timeout}
      end
    end
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) -> pid
      _other -> nil
    end
  end

  defp kill_os_process(nil), do: :ok

  defp kill_os_process(pid) when is_integer(pid) do
    _ = System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    wait_until_dead(pid, monotonic_ms() + @kill_grace_ms)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp wait_until_dead(pid, deadline) do
    if os_process_alive?(pid) and monotonic_ms() < deadline do
      Process.sleep(10)
      wait_until_dead(pid, deadline)
    else
      :ok
    end
  end

  defp os_process_alive?(pid) when is_integer(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_out, 0} -> true
      _other -> false
    end
  rescue
    _error -> false
  end

  defp close_port(port) do
    if Port.info(port) do
      Port.close(port)
    else
      :ok
    end
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp drain_port(port) do
    receive do
      {^port, _msg} -> drain_port(port)
    after
      0 -> :ok
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp split_records(binary) do
    binary
    |> :binary.split(<<0>>, [:global, :trim_all])
    |> Enum.reject(&(&1 == ""))
  end

  defp walk_records([], paths, _count), do: {:ok, Enum.reverse(paths)}

  defp walk_records(_records, _paths, count) when count >= @max_paths do
    {:error, :path_count_exceeded}
  end

  defp walk_records([record | rest], paths, count) do
    case parse_xy_record(record) do
      {:ordinary, path} ->
        walk_records(rest, [path | paths], count + 1)

      {:rename, first_path} ->
        consume_rename(rest, first_path, paths, count)

      :error ->
        {:error, :malformed_output}
    end
  end

  defp consume_rename([second_path | rest], first_path, paths, count) do
    next_count = count + 2

    cond do
      not valid_path?(second_path) ->
        {:error, :malformed_output}

      next_count > @max_paths ->
        {:error, :path_count_exceeded}

      true ->
        walk_records(rest, [second_path, first_path | paths], next_count)
    end
  end

  defp consume_rename([], _first_path, _paths, _count), do: {:error, :malformed_output}

  defp parse_xy_record(<<x, y, ?\s, path::binary>>)
       when is_integer(x) and is_integer(y) and path != "" do
    if valid_path?(path) do
      if rename_or_copy?(x, y), do: {:rename, path}, else: {:ordinary, path}
    else
      :error
    end
  end

  defp parse_xy_record(_record), do: :error

  defp rename_or_copy?(x, y), do: x in [?R, ?C] or y in [?R, ?C]

  defp valid_path?(path) when is_binary(path) do
    path != "" and String.valid?(path) and not String.contains?(path, <<0>>)
  end

  defp valid_path?(_path), do: false
end
