defmodule Arbor.Shell.DuplexStdinBackpressureSecurityRegressionTest do
  @moduledoc """
  Security regressions for native duplex-stdin backpressure.

  Base revision (blocking launcher stdin write) deadlocks under full-pipe duplex
  or misses timeout/owner-loss containment while a write is blocked. Candidate
  must: nonblocking child-stdin writes, at most one pending IO_CHUNK frame,
  poll-driven duplex (output + controller HUP/ERR + conditional POLLOUT), frame
  interactive and one-shot input at 8192 bytes, and reject interactive calls
  above MAX_CONTROL_PACKET - 1 with a stable error.

  Hang-capable targets use sh builtins only (no external sleep/fork/cat). Unique
  markers are passed as `sh -c` argv0 (`$0`) so leftovers are identifiable on
  the actual target process.
  """

  use ExUnit.Case, async: false

  alias Arbor.Shell
  alias Arbor.Shell.PortSession

  # Real OS pipe/backpressure cases — not part of mix test.fast.
  @moduletag :slow
  @moduletag :security_regression

  # Comfortably above typical OS pipe capacity (~64 KiB) so duplex backpressure
  # is unavoidable without concurrent output drain + nonblocking stdin write.
  @above_pipe_capacity 256 * 1024
  # Native MAX_CONTROL_PACKET is 16 MiB including the 1-byte command tag.
  @max_interactive_payload 16 * 1024 * 1024 - 1
  @marker_prefix "arbor_duplex_bp_"
  # Builtin line duplex: read line, printf back with newline (byte-exact for
  # newline-terminated payloads). Marker is argv0 via `sh -c script marker`.
  @duplex_script "while IFS= read -r line || [ -n \"$line\" ]; do printf '%s\\n' \"$line\"; done"
  @hang_script "while :; do :; done"
  @one_shot_bound_ms 20_000

  setup do
    on_exit(fn ->
      kill_marked_leftovers()
      refute_marked_processes()
    end)

    :ok
  end

  test "security regression: one-shot duplex payload above pipe capacity completes byte-exact" do
    marker = unique_marker("oneshot")
    # 15-byte body + "\n" = 16-byte lines so exact capacity multiples.
    payload = newline_payload("0123456789abcde", @above_pipe_capacity)
    assert byte_size(payload) == @above_pipe_capacity
    assert String.ends_with?(payload, "\n")

    task =
      Task.async(fn ->
        Shell.execute_direct("sh", ["-c", @duplex_script, marker],
          sandbox: :none,
          stdin: payload,
          timeout: 15_000,
          max_output_bytes: byte_size(payload) + 1
        )
      end)

    # Base revision may deadlock; bound the wait and clean markers rather than
    # depending on the global ExUnit timeout.
    case Task.yield(task, @one_shot_bound_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} ->
        assert result.exit_code == 0
        refute result.timed_out
        refute result.killed
        # Byte-exact echo after one-shot close_stdin proves close-after-pending
        # ordering: all framed INPUT is delivered before EOF.
        assert result.stdout == payload

      {:ok, other} ->
        kill_marked_leftovers()
        flunk("one-shot duplex failed: #{inspect(other)}")

      nil ->
        kill_marked_leftovers()
        flunk("one-shot duplex hung past #{@one_shot_bound_ms}ms (base-revision deadlock?)")
    end

    assert eventually?(fn -> not marked_process_alive?(marker) end, 5_000)
  end

  test "security regression: output-amplified duplex cannot deadlock child stdin" do
    marker = unique_marker("amplified")
    payload = newline_payload("0123456789abcde", @above_pipe_capacity)
    output_chunk = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    output_repetitions = 8_192
    expected_output_bytes = byte_size(output_chunk) * output_repetitions

    script = """
    first=1
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$first" -eq 1 ]; then
        i=0
        while [ "$i" -lt #{output_repetitions} ]; do
          printf '%s' '#{output_chunk}'
          i=$((i + 1))
        done
        first=0
      fi
    done
    """

    task =
      Task.async(fn ->
        Shell.execute_direct("sh", ["-c", script, marker],
          sandbox: :none,
          stdin: payload,
          timeout: 15_000,
          max_output_bytes: expected_output_bytes + 1
        )
      end)

    case Task.yield(task, @one_shot_bound_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} ->
        assert result.exit_code == 0
        refute result.timed_out
        refute result.killed
        assert byte_size(result.stdout) == expected_output_bytes

      {:ok, other} ->
        kill_marked_leftovers()
        flunk("output-amplified duplex failed: #{inspect(other)}")

      nil ->
        kill_marked_leftovers()
        flunk("output-amplified duplex deadlocked past #{@one_shot_bound_ms}ms")
    end

    assert eventually?(fn -> not marked_process_alive?(marker) end, 5_000)
  end

  test "security regression: interactive PortSession duplex above pipe capacity stays ordered" do
    marker = unique_marker("interactive")
    payload = newline_payload("abcdefghijklmno", @above_pipe_capacity)
    assert byte_size(payload) == @above_pipe_capacity
    # Second framed write after the large payload — proves stdin remains open
    # and frame order is preserved. (PortSession has no public close-input API.)
    tail = "ORDERED-TAIL-FRAME\n"

    {:ok, pid} =
      PortSession.start_link_direct(
        "sh",
        ["-c", @duplex_script, marker],
        "sh -c duplex #{marker}",
        stream_to: self(),
        timeout: 30_000,
        max_output_bytes: byte_size(payload) + byte_size(tail) + 1
      )

    id = PortSession.get_id(pid)
    on_exit(fn -> if Process.alive?(pid), do: PortSession.kill(pid) end)

    assert :ok = PortSession.send_input(pid, payload)
    delivered = collect_stream(id, <<>>, byte_size(payload), 20_000)
    assert delivered == payload

    assert :ok = PortSession.send_input(pid, tail)
    tail_delivered = collect_stream(id, <<>>, byte_size(tail), 5_000)
    assert tail_delivered == tail

    PortSession.kill(pid)
    assert eventually?(fn -> not marked_process_alive?(marker) end, 5_000)
  end

  test "security regression: interactive call above aggregate ceiling fails immediately with stable error" do
    marker = unique_marker("ceiling")

    {:ok, pid} =
      PortSession.start_link_direct(
        "sh",
        ["-c", @duplex_script, marker],
        "sh -c duplex #{marker}",
        stream_to: self(),
        timeout: 10_000,
        max_output_bytes: 64
      )

    on_exit(fn -> if Process.alive?(pid), do: PortSession.kill(pid) end)

    oversized = :binary.copy("X", @max_interactive_payload + 1)

    # Must reject in-process before queueing unbounded native frames.
    assert {:error, :stdin_input_too_large} = PortSession.send_input(pid, oversized)
    # nil is invalid interactive input, not a size-ceiling miss.
    assert {:error, :invalid_shell_input} = PortSession.send_input(pid, nil)

    # Session remains usable for a bounded follow-up write.
    assert :ok = PortSession.send_input(pid, "ok\n")
    id = PortSession.get_id(pid)
    assert_receive {:port_data, ^id, "ok\n"}, 5_000

    PortSession.kill(pid)
    assert eventually?(fn -> not marked_process_alive?(marker) end, 5_000)
  end

  test "security regression: non-reading builtin is observed alive then timeout contains without leftovers" do
    marker = unique_marker("to")
    # Large stdin against a non-reading target fills pipes and holds a pending
    # native frame; absolute timeout must still fire and contain the group.
    payload = newline_payload("BBBBBBBBBBBBBBB", @above_pipe_capacity)

    task =
      Task.async(fn ->
        Shell.execute_direct("sh", ["-c", @hang_script, marker],
          sandbox: :none,
          stdin: payload,
          timeout: 1_500,
          max_output_bytes: 1
        )
      end)

    assert eventually?(fn -> marked_target_alive?(marker) end, 3_000),
           "expected marked non-reading target #{marker} to be observed alive before timeout"

    result =
      case Task.yield(task, 15_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, value} ->
          value

        nil ->
          kill_marked_leftovers()
          flunk("timeout case hung past bound without returning")
      end

    # Framing timeout under backpressure must project the exact public timeout
    # flag — not only a generic killed/137 envelope.
    assert {:ok, %{timed_out: true, exit_code: 137}} = result

    assert eventually?(fn -> not marked_process_alive?(marker) end, 5_000),
           "timeout must contain marked target and launcher for #{marker}"
  end

  test "security regression: killing owner during backpressure contains marked target and launcher" do
    marker = unique_marker("own")
    payload = newline_payload("CCCCCCCCCCCCCCC", @above_pipe_capacity)

    owner =
      spawn(fn ->
        _ =
          Shell.execute_direct("sh", ["-c", @hang_script, marker],
            sandbox: :none,
            stdin: payload,
            timeout: 60_000,
            max_output_bytes: 1
          )

        Process.sleep(60_000)
      end)

    assert eventually?(fn -> marked_target_alive?(marker) end, 5_000),
           "expected marked target under backpressure before owner kill"

    Process.exit(owner, :kill)

    assert eventually?(fn -> not marked_process_alive?(marker) end, 8_000),
           "owner death must contain marked target and launcher for #{marker}"
  end

  test "security regression: interactive cancel while send_input is backpressured contains exactly" do
    marker = unique_marker("icancel")
    payload = newline_payload("DDDDDDDDDDDDDDD", @above_pipe_capacity)

    {:ok, pid} =
      PortSession.start_link_direct(
        "sh",
        ["-c", @hang_script, marker],
        "sh -c hang #{marker}",
        stream_to: self(),
        timeout: 60_000,
        max_output_bytes: 1
      )

    id = PortSession.get_id(pid)
    on_exit(fn -> if Process.alive?(pid), do: PortSession.kill(pid) end)

    # Unlinked monitored sender so a session exit cannot mask the framing reply.
    sender = start_monitored_sender(fn -> PortSession.send_input(pid, payload) end)

    assert eventually?(fn -> marked_target_alive?(marker) end, 5_000),
           "expected marked non-reading target under interactive backpressure before cancel"

    # Prove send_input is still blocked in nosuspend framing (no reply yet).
    assert yield_monitored_sender(sender, 300) == nil,
           "send_input must still be backpressured before public kill"

    # Public kill form: {:cancel_shell_execution, nil}. Framing must observe it
    # while nosuspend retries rather than queueing until the absolute deadline.
    assert :ok = PortSession.kill(pid)

    assert {:ok, {:error, :cancelled}} = yield_monitored_sender(sender, 10_000),
           "expected exact framing cancel result from backpressured send_input"

    assert eventually?(fn -> not Process.alive?(pid) end, 5_000)
    refute Process.alive?(pid)

    assert eventually?(fn -> not marked_process_alive?(marker) end, 8_000),
           "interactive cancel must contain marked target and launcher for #{marker} (id=#{id})"
  end

  test "security regression: interactive supervised-owner loss while send_input is backpressured contains" do
    marker = unique_marker("iown")
    payload = newline_payload("EEEEEEEEEEEEEEE", @above_pipe_capacity)
    test_pid = self()

    # Production path: supervised session owned by the spawned process only
    # through owner_ref monitor/DOWN — not start_link's process link EXIT.
    owner =
      spawn(fn ->
        case PortSession.start_supervised_direct(
               "sh",
               ["-c", @hang_script, marker],
               "sh -c hang #{marker}",
               stream_to: test_pid,
               timeout: 60_000,
               max_output_bytes: 1
             ) do
          {:ok, session} ->
            send(test_pid, {:session_ready, session})
            Process.sleep(120_000)

          other ->
            send(test_pid, {:session_failed, other})
        end
      end)

    session =
      receive do
        {:session_ready, pid} when is_pid(pid) -> pid
        {:session_failed, other} -> flunk("failed to start owned session: #{inspect(other)}")
      after
        5_000 -> flunk("owned session did not start")
      end

    on_exit(fn -> if Process.alive?(session), do: PortSession.kill(session) end)

    sender = start_monitored_sender(fn -> PortSession.send_input(session, payload) end)

    assert eventually?(fn -> marked_target_alive?(marker) end, 5_000),
           "expected marked target under interactive backpressure before owner kill"

    # Prove send_input is still blocked in nosuspend framing (no reply yet).
    assert yield_monitored_sender(sender, 300) == nil,
           "send_input must still be backpressured before owner loss"

    Process.exit(owner, :kill)

    assert {:ok, {:error, :caller_dead}} = yield_monitored_sender(sender, 10_000),
           "expected exact owner-DOWN framing result from backpressured send_input"

    assert eventually?(fn -> not Process.alive?(session) end, 5_000)

    assert eventually?(fn -> not marked_process_alive?(marker) end, 8_000),
           "owner death during interactive backpressure must contain marked processes for #{marker}"
  end

  test "security regression: supervised owner loss while initial stdin is backpressured contains" do
    marker = unique_marker("istart")
    payload = newline_payload("GGGGGGGGGGGGGGG", @above_pipe_capacity)
    test_pid = self()

    # Owner blocks in DynamicSupervisor.start_child while PortSession init frames
    # large initial stdin. Only the production owner_ref monitor/DOWN path must
    # observe loss (start_supervised_direct, not start_link).
    owner =
      spawn(fn ->
        result =
          PortSession.start_supervised_direct(
            "sh",
            ["-c", @hang_script, marker],
            "sh -c hang #{marker}",
            stream_to: test_pid,
            timeout: 60_000,
            max_output_bytes: 1,
            stdin: payload
          )

        send(test_pid, {:start_result, result})
      end)

    assert eventually?(fn -> marked_target_alive?(marker) end, 5_000),
           "expected marked target while initial stdin is framed under backpressure"

    # Prove open_and_start is still blocked framing initial stdin (owner has not
    # returned from start_supervised_direct).
    refute_receive {:start_result, _}, 300

    Process.exit(owner, :kill)

    # start/3 framing observes owner DOWN, contains once, and fails closed.
    # The blocked start_child never delivers success to the dead owner.
    assert eventually?(fn -> not marked_process_alive?(marker) end, 8_000),
           "owner death during initial-stdin backpressure must contain marked target and launcher for #{marker}"

    # No successful session may remain registered after owner-loss containment.
    refute_receive {:start_result, {:ok, _session}}, 500
  end

  test "security regression: public async one-shot cancel while initial stdin is backpressured" do
    marker = unique_marker("async")
    payload = newline_payload("FFFFFFFFFFFFFFF", @above_pipe_capacity)

    # Marker embedded in the command string so leftovers remain identifiable
    # through public execute_async (string command path).
    command = "sh -c 'while :; do :; done' #{marker}"

    assert {:ok, exec_id} =
             Shell.execute_async(command,
               sandbox: :none,
               stdin: payload,
               timeout: 60_000,
               max_output_bytes: 1
             )

    assert eventually?(fn -> marked_target_alive?(marker) end, 5_000),
           "expected marked target under async one-shot stdin backpressure before cancel"

    # Public async cancel; kill may return :ok once terminal, or a short
    # wait timeout while containment finishes — either way the registry result
    # must project cancelled and processes must be gone.
    kill_result = Shell.kill(exec_id)

    assert kill_result in [:ok, {:error, :cancellation_timeout}, {:error, :not_running}],
           "unexpected kill result: #{inspect(kill_result)}"

    result =
      case Shell.get_result(exec_id, wait: true, timeout: 15_000) do
        {:ok, value} when is_map(value) ->
          value

        other ->
          kill_marked_leftovers()
          flunk("async cancel did not yield a terminal result: #{inspect(other)}")
      end

    # Exact cancellation projection from the public async path.
    assert Map.get(result, :cancelled) == true,
           "expected cancelled: true, got: #{inspect(result)}"

    assert Map.get(result, :killed) == true
    assert Map.get(result, :exit_code) == 137
    assert Map.get(result, :timed_out) != true

    assert eventually?(fn -> not marked_process_alive?(marker) end, 8_000),
           "async cancel under stdin backpressure must contain marked target and launcher for #{marker}"
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Non-linking monitored sender: Task.async links the test process and can
  # mask framing replies if the session owner exits kill the sender first.
  defp start_monitored_sender(fun) when is_function(fun, 0) do
    parent = self()
    reply_ref = make_ref()

    pid =
      spawn(fn ->
        result =
          try do
            fun.()
          catch
            kind, reason -> {:sender_caught, kind, reason}
          end

        send(parent, {reply_ref, result})
      end)

    {pid, Process.monitor(pid), reply_ref}
  end

  # Returns nil on timeout (still blocked), {:ok, result} on reply, or
  # {:exit, reason} if the sender died without publishing a result.
  defp yield_monitored_sender({_pid, mon, reply_ref}, timeout_ms)
       when is_reference(mon) and is_reference(reply_ref) and is_integer(timeout_ms) do
    receive do
      {^reply_ref, result} ->
        Process.demonitor(mon, [:flush])
        {:ok, result}

      {:DOWN, ^mon, :process, _pid, reason} ->
        receive do
          {^reply_ref, result} -> {:ok, result}
        after
          0 -> {:exit, reason}
        end
    after
      max(timeout_ms, 0) -> nil
    end
  end

  defp unique_marker(kind) when is_binary(kind) do
    "#{@marker_prefix}#{kind}_#{System.unique_integer([:positive])}"
  end

  # Newline-structured payload of exact byte size (line body + "\n" copies).
  defp newline_payload(line_body, target_bytes)
       when is_binary(line_body) and is_integer(target_bytes) and target_bytes > 0 do
    line = line_body <> "\n"
    line_size = byte_size(line)
    count = div(target_bytes, line_size)
    payload = :binary.copy(line, count)
    assert byte_size(payload) == target_bytes
    payload
  end

  defp collect_stream(id, acc, target_size, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_collect_stream(id, acc, target_size, deadline)
  end

  defp do_collect_stream(id, acc, target_size, deadline) do
    if byte_size(acc) >= target_size do
      acc
    else
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining <= 0 do
        flunk("timed out collecting stream for #{id}: have #{byte_size(acc)} want #{target_size}")
      else
        receive do
          {:port_data, ^id, chunk} when is_binary(chunk) ->
            do_collect_stream(id, acc <> chunk, target_size, deadline)

          {:port_exit, ^id, code, output} ->
            combined = acc <> output

            if byte_size(combined) >= target_size do
              binary_part(combined, 0, target_size)
            else
              flunk(
                "port exited #{code} with #{byte_size(combined)} bytes before reaching #{target_size}"
              )
            end
        after
          max(remaining, 1) ->
            flunk(
              "timed out collecting stream for #{id}: have #{byte_size(acc)} want #{target_size}"
            )
        end
      end
    end
  end

  defp marked_target_alive?(marker) when is_binary(marker) do
    Enum.any?(os_processes(), fn process ->
      not String.contains?(process.command, "arbor_shell_launcher") and
        marked_command?(process.command, marker)
    end)
  end

  defp marked_process_alive?(marker) when is_binary(marker) do
    Enum.any?(os_processes(), &marked_command?(&1.command, marker))
  end

  defp marked_command?(command, marker)
       when is_binary(command) and is_binary(marker) and marker != "" do
    String.contains?(command, marker)
  end

  defp kill_marked_leftovers do
    # Multiple kill passes plus eventual absence — one kill + 50ms is not enough
    # under suite load when the base revision left a blocked launcher/target.
    Enum.each(1..8, fn _pass ->
      os_processes()
      |> Enum.filter(&String.contains?(&1.command, @marker_prefix))
      |> Enum.each(fn process ->
        _ =
          System.cmd("/bin/kill", ["-KILL", Integer.to_string(process.pid)],
            stderr_to_stdout: true
          )
      end)

      Process.sleep(50)
    end)

    unless eventually?(
             fn ->
               Enum.all?(os_processes(), fn process ->
                 not String.contains?(process.command, @marker_prefix)
               end)
             end,
             3_000
           ) do
      # Final force pass before the assertion in refute_marked_processes/0.
      os_processes()
      |> Enum.filter(&String.contains?(&1.command, @marker_prefix))
      |> Enum.each(fn process ->
        _ =
          System.cmd("/bin/kill", ["-KILL", Integer.to_string(process.pid)],
            stderr_to_stdout: true
          )
      end)

      Process.sleep(100)
    end
  end

  defp refute_marked_processes do
    leftovers =
      os_processes()
      |> Enum.filter(&String.contains?(&1.command, @marker_prefix))
      |> Enum.map(& &1.command)

    assert leftovers == [],
           "marked duplex-backpressure leftovers still alive: #{inspect(leftovers)}"
  end

  defp eventually?(fun, timeout_ms) when is_function(fun, 0) and is_integer(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually?(fun, deadline)
  end

  defp do_eventually?(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(20)
        do_eventually?(fun, deadline)
      end
    end
  end

  defp os_processes do
    {output, 0} = System.cmd("ps", ["-axo", "pid=,ppid=,pgid=,command="])

    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\s*(\d+)\s+(\d+)\s+(\d+)\s+(.+)$/, line) do
        [_, pid, ppid, pgid, command] ->
          [
            %{
              pid: String.to_integer(pid),
              ppid: String.to_integer(ppid),
              pgid: String.to_integer(pgid),
              command: command
            }
          ]

        _other ->
          []
      end
    end)
  end
end
