defmodule Arbor.Shell.Executor do
  @moduledoc """
  Low-level command execution using Erlang ports.

  Handles the actual execution of shell commands with timeout handling,
  output capture, and process management.

  Uses `{:spawn_executable, path}` with explicit args to avoid shell
  metacharacter interpretation. Commands are resolved to full paths and
  arguments are passed directly to the executable.

  ## Security bounds

  - **Absolute timeout** — measured from command start via a monotonic
    deadline. Continuous output cannot reset the timer.
  - **Output ceiling** — at most `max_output_bytes` of the merged stdout
    stream are retained (`:stderr_to_stdout`; result `stderr` is always `""`).
    Default is 8 MiB (`8_388_608`); system hard maximum is 16 MiB
    (`16_777_216`) — larger positive values are normalized down to the hard
    maximum (non-bypassable). Termination happens when a new chunk *would
    exceed* that ceiling (exactly `max_output_bytes` is allowed). The OS
    process is then SIGKILL'd and the port closed so an untrusted producer
    cannot force unbounded retention or delayed side effects.
  - **UTF-8 safe truncation** — `stdout` is a `String.t()`. When the ceiling
    cuts mid-codepoint, the returned prefix is trimmed to a valid UTF-8
    boundary so JSON/checkpoint consumers are not handed a broken binary.
  """

  alias Arbor.Shell.Sandbox

  @default_timeout 30_000
  # Headroom for Mix/compiler/test validation logs while remaining bounded.
  # Callers that need a tighter cap pass an explicit `:max_output_bytes`.
  @default_max_output_bytes 8_388_608
  # Non-bypassable system hard maximum. Callers cannot request more retention
  # than this; larger positive values clamp down (invalid/non-positive → default).
  @max_max_output_bytes 16_777_216

  # After hard-kill + Port.close, terminal/data port messages can still race
  # into the caller's mailbox (Port.close does not synchronously flush the
  # driver). Drain under a *fixed absolute* grace: non-blocking flush → fixed
  # sleep → non-blocking flush. Arriving messages never extend the wait (would
  # re-create an inactivity-reset loop). Bound: exactly @port_drain_grace_ms of
  # wall sleep plus ≤ @port_drain_max_msgs discards across both sweeps.
  @port_drain_grace_ms 100
  @port_drain_max_msgs 256

  # Never PATH-resolve `kill`. Closed absolute Unix fallbacks only — do not
  # recurse through Arbor.Shell (would re-enter auth/sandbox/executor).
  @kill_executables ["/bin/kill", "/usr/bin/kill"]

  @type result :: %{
          exit_code: non_neg_integer(),
          stdout: String.t(),
          stderr: String.t(),
          duration_ms: non_neg_integer(),
          timed_out: boolean(),
          killed: boolean(),
          output_truncated: boolean(),
          output_limit_exceeded: boolean()
        }

  @doc """
  Execute a command synchronously.

  ## Options

  - `:timeout` - Absolute timeout in milliseconds measured from command start
    (default: 30_000). Continuous output does not extend the deadline.
  - `:max_output_bytes` - Maximum retained bytes of the merged stdout stream
    (`:stderr_to_stdout`; result `stderr` is `""`). Default: 8_388_608 (8 MiB).
    Hard maximum: 16_777_216 (16 MiB) — larger positive values are clamped down.
    When a chunk would cause retained output to *exceed* this ceiling the
    process is killed immediately and the result is marked with
    `output_limit_exceeded: true` / `output_truncated: true`. Output of exactly
    `max_output_bytes` is allowed. Truncation trims to a valid UTF-8 prefix
    (may be slightly under the ceiling). Invalid or non-positive values fall
    back to the default.
  - `:cwd` - Working directory
  - `:env` - Environment variables map
  - `:stdin` - Input to send to the process
  """
  @spec run(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(command, opts \\ []) do
    timeout = normalize_timeout(Keyword.get(opts, :timeout, @default_timeout))
    max_output_bytes = normalize_max_output_bytes(Keyword.get(opts, :max_output_bytes))
    cwd = Keyword.get(opts, :cwd)
    env = Keyword.get(opts, :env, %{})
    stdin = Keyword.get(opts, :stdin)

    start_time = System.monotonic_time(:millisecond)

    with :ok <- validate_cwd(cwd),
         {:ok, executable, args} <- resolve_command(command) do
      port_opts = build_port_opts(executable, args, cwd, env)

      try do
        port = Port.open({:spawn_executable, to_charlist(executable)}, port_opts)

        if stdin do
          Port.command(port, stdin)
        end

        collect_output(port, timeout, start_time, max_output_bytes)
      catch
        :error, reason ->
          {:error, reason}
      end
    end
  end

  @doc """
  Execute a command with pre-parsed executable and arguments.

  Unlike `run/2`, this skips shell string parsing — the executable name
  and args are passed directly to Port.open. Use this when you already
  have structured {cmd, args} and want to avoid the parse round-trip.

  ## Options

  Same as `run/2` (identical timeout, output-ceiling, and kill semantics):
  - `:timeout` - Absolute timeout in milliseconds measured from command start
    (default: 30_000)
  - `:max_output_bytes` - Maximum retained merged-stdout bytes (default:
    8_388_608 / 8 MiB; hard maximum 16_777_216 / 16 MiB). Terminates when a
    chunk would *exceed* the ceiling. Result `stderr` is always empty
    (`:stderr_to_stdout`).
  - `:cwd` - Working directory
  - `:env` - Environment variables map
  - `:stdin` - Input to send to the process
  """
  @spec run_direct(String.t(), [String.t()], keyword()) :: {:ok, result()} | {:error, term()}
  def run_direct(cmd, args, opts \\ []) do
    timeout = normalize_timeout(Keyword.get(opts, :timeout, @default_timeout))
    max_output_bytes = normalize_max_output_bytes(Keyword.get(opts, :max_output_bytes))
    cwd = Keyword.get(opts, :cwd)
    env = Keyword.get(opts, :env, %{})
    stdin = Keyword.get(opts, :stdin)

    start_time = System.monotonic_time(:millisecond)

    with :ok <- validate_cwd(cwd),
         {:ok, executable} <- Sandbox.resolve_executable(cmd) do
      port_opts = build_port_opts(executable, args, cwd, env)

      try do
        port = Port.open({:spawn_executable, to_charlist(executable)}, port_opts)

        if stdin do
          Port.command(port, stdin)
        end

        collect_output(port, timeout, start_time, max_output_bytes)
      catch
        :error, reason ->
          {:error, reason}
      end
    else
      {:error, :executable_not_found} -> {:error, {:executable_not_found, cmd}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Kill a port/process by port reference.

  Signals the OS pid (best-effort SIGKILL via absolute kill binaries) before
  closing the BEAM port so delayed side effects cannot continue after close.
  """
  @spec kill_port(port()) :: :ok | {:error, term()}
  def kill_port(port) when is_port(port) do
    # Best-effort OS kill (no-op if port already dead / has no os_pid).
    _ = signal_port_os_pid(port)

    Port.close(port)
    :ok
  catch
    :error, reason -> {:error, reason}
  end

  # Focused-regression seam: default 8 MiB, hard max 16 MiB (clamp larger
  # positive values; invalid/non-positive → default). Same path as run/run_direct.
  @doc false
  @spec normalize_max_output_bytes(term()) :: pos_integer()
  def normalize_max_output_bytes(n) when is_integer(n) and n > 0,
    do: min(n, @max_max_output_bytes)

  def normalize_max_output_bytes(_n), do: @default_max_output_bytes

  # Private functions

  # `after 0` in receive fires immediately. Callers that pass timeout: 0/1
  # (often LLM-filled optional tool args) must not instantly SIGKILL the port.
  # Keep small positive values (e.g. 100ms) so unit tests can exercise timeout.
  defp normalize_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout
  defp normalize_timeout(_timeout), do: @default_timeout

  defp resolve_command(command) do
    {cmd, args} = Sandbox.parse_command(command)

    case Sandbox.resolve_executable(cmd) do
      {:ok, path} -> {:ok, path, args}
      {:error, :executable_not_found} -> {:error, {:executable_not_found, cmd}}
    end
  end

  defp build_port_opts(_executable, args, cwd, env) do
    opts = [
      :binary,
      :exit_status,
      :use_stdio,
      :stderr_to_stdout,
      args: Enum.map(args, &to_charlist/1)
    ]

    opts =
      if cwd do
        [{:cd, to_charlist(cwd)} | opts]
      else
        opts
      end

    if map_size(env) > 0 do
      env_list =
        Enum.map(env, fn
          # Port.open convention: {var, false} removes the variable
          {k, false} -> {to_charlist(k), false}
          {k, v} -> {to_charlist(k), to_charlist(v)}
        end)

      [{:env, env_list} | opts]
    else
      opts
    end
  end

  defp validate_cwd(nil), do: :ok

  defp validate_cwd(cwd) when is_binary(cwd) do
    if File.dir?(cwd) do
      :ok
    else
      {:error, {:invalid_cwd, cwd}}
    end
  end

  defp collect_output(port, timeout, start_time, max_output_bytes) do
    deadline = start_time + timeout
    collect_output(port, deadline, start_time, max_output_bytes, [], 0)
  end

  defp collect_output(port, deadline, start_time, max_output_bytes, acc, acc_bytes) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      finish_timeout(port, start_time, acc)
    else
      receive do
        {^port, {:data, data}} when is_binary(data) ->
          handle_data(port, deadline, start_time, max_output_bytes, acc, acc_bytes, data)

        {^port, {:exit_status, exit_code}} ->
          finish_ok(start_time, acc, exit_code)
      after
        remaining ->
          finish_timeout(port, start_time, acc)
      end
    end
  end

  defp handle_data(port, deadline, start_time, max_output_bytes, acc, acc_bytes, data) do
    data_size = byte_size(data)
    new_bytes = acc_bytes + data_size

    # Terminate only when the chunk would *exceed* the ceiling. Exactly
    # max_output_bytes of retained output is allowed.
    if new_bytes > max_output_bytes do
      room = max_output_bytes - acc_bytes

      new_acc =
        if room > 0 do
          [binary_part(data, 0, room) | acc]
        else
          acc
        end

      # Kill immediately — do not keep draining an untrusted producer.
      finish_output_limit(port, start_time, new_acc)
    else
      collect_output(port, deadline, start_time, max_output_bytes, [data | acc], new_bytes)
    end
  end

  defp finish_ok(start_time, acc, exit_code) do
    duration = System.monotonic_time(:millisecond) - start_time
    output = acc_to_binary(acc)

    {:ok,
     %{
       exit_code: exit_code,
       stdout: output,
       stderr: "",
       duration_ms: duration,
       timed_out: false,
       killed: false,
       output_truncated: false,
       output_limit_exceeded: false
     }}
  end

  defp finish_timeout(port, start_time, acc) do
    hard_kill_port(port)
    duration = System.monotonic_time(:millisecond) - start_time
    output = acc_to_binary(acc)

    {:ok,
     %{
       exit_code: 137,
       stdout: output,
       stderr: "",
       duration_ms: duration,
       timed_out: true,
       killed: true,
       output_truncated: false,
       output_limit_exceeded: false
     }}
  end

  defp finish_output_limit(port, start_time, acc) do
    hard_kill_port(port)
    duration = System.monotonic_time(:millisecond) - start_time
    # Byte ceiling can split a multibyte codepoint; keep a valid String.t prefix.
    output = acc |> acc_to_binary() |> utf8_safe_prefix()

    {:ok,
     %{
       exit_code: 137,
       stdout: output,
       stderr: "",
       duration_ms: duration,
       timed_out: false,
       killed: true,
       output_truncated: true,
       output_limit_exceeded: true
     }}
  end

  defp acc_to_binary(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  # When max_output_bytes cuts mid-codepoint, drop 1..3 trailing bytes (UTF-8
  # max sequence length is 4) until the prefix is valid. If the stream itself
  # is not valid UTF-8, fall back to the first valid prefix from :unicode.
  defp utf8_safe_prefix(data) when is_binary(data) do
    if String.valid?(data) do
      data
    else
      size = byte_size(data)

      Enum.find_value(1..min(3, size), fn n ->
        candidate = binary_part(data, 0, size - n)
        if String.valid?(candidate), do: candidate
      end) ||
        case :unicode.characters_to_binary(data) do
          valid when is_binary(valid) -> valid
          {:incomplete, good, _} when is_binary(good) -> good
          {:error, good, _} when is_binary(good) -> good
          _ -> <<>>
        end
    end
  end

  # Port.close alone only drops the BEAM-side port; an external producer that
  # has already finished writing (or ignores SIGPIPE) can keep running and
  # perform delayed side effects. SIGKILL the OS pid first (absolute kill
  # binary, never PATH), then close, then drain late {port, _} / {:EXIT, port, _}
  # under an absolute grace bound.
  defp hard_kill_port(port) do
    _ = signal_port_os_pid(port)
    catch_port_close(port)
    drain_port_mailbox(port)
  end

  defp signal_port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) and os_pid > 0 ->
        send_sigkill(os_pid)

      _ ->
        :ok
    end
  catch
    :error, _ -> :ok
  end

  # Best-effort: try closed absolute paths only. Never System.cmd("kill", ...)
  # (PATH-resolved). Never Arbor.Shell. On miss/failure, Port.close still runs.
  defp send_sigkill(os_pid) when is_integer(os_pid) and os_pid > 0 do
    pid_str = Integer.to_string(os_pid)

    Enum.find_value(@kill_executables, :unavailable, fn path ->
      if File.regular?(path) do
        try do
          case System.cmd(path, ["-9", pid_str], stderr_to_stdout: true) do
            {_out, 0} -> :ok
            _ -> false
          end
        rescue
          _ -> false
        catch
          # System.cmd can also exit the calling process on rare spawn failures.
          :exit, _ -> false
        end
      else
        false
      end
    end)

    :ok
  end

  defp catch_port_close(port) do
    Port.close(port)
  catch
    :error, _ -> :ok
  end

  # Fixed absolute drain — never restart the wait on arrivals.
  defp drain_port_mailbox(port) do
    count = flush_port_messages(port, 0)
    Process.sleep(@port_drain_grace_ms)
    _ = flush_port_messages(port, count)
    :ok
  end

  defp flush_port_messages(_port, count) when count >= @port_drain_max_msgs, do: count

  defp flush_port_messages(port, count) do
    receive do
      {^port, _} -> flush_port_messages(port, count + 1)
      {:EXIT, ^port, _} -> flush_port_messages(port, count + 1)
    after
      0 -> count
    end
  end
end
