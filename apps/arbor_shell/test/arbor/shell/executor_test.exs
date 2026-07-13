defmodule Arbor.Shell.ExecutorTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Shell
  alias Arbor.Shell.Executor

  # Finite noisy producer: emits more frequently than a short absolute timeout
  # for a bounded duration, then exits. Never use `while true` — on pre-fix
  # base, killing the BEAM owner can leave the OS shell running forever.
  # ~60 * 10ms ≈ 600ms total wall if allowed to finish; absolute timeout
  # (~100ms) should cut far earlier. Outer Task.yield (~1.5–2s) is only a
  # safety net so base fails promptly without orphaning OS shells.
  @finite_noisy_python ~s{import sys,time; [(sys.stdout.write("x\\n"), sys.stdout.flush(), time.sleep(0.01)) for _ in range(60)]}
  @finite_noisy_cmd "python3 -c '#{@finite_noisy_python}'"

  describe "run/2" do
    test "executes command and returns result" do
      {:ok, result} = Executor.run("echo executor_test")

      assert result.exit_code == 0
      assert String.contains?(result.stdout, "executor_test")
      assert result.timed_out == false
      assert result.killed == false
      assert result.output_limit_exceeded == false
      assert result.output_truncated == false
      assert is_integer(result.duration_ms)
    end

    test "handles command with environment variables" do
      {:ok, result} = Executor.run("sh -c 'echo $TEST_VAR'", env: %{"TEST_VAR" => "hello"})

      assert result.exit_code == 0
      assert String.trim(result.stdout) == "hello"
    end

    test "handles command with working directory" do
      {:ok, result} = Executor.run("pwd", cwd: "/tmp")

      assert String.trim(result.stdout) in ["/tmp", "/private/tmp"]
    end

    test "handles command with stdin" do
      {:ok, result} = Executor.run("cat", stdin: "test input", timeout: 2000)

      assert String.contains?(result.stdout, "test input")
    end

    test "one-shot closes stdin so EOF readers exit with exact bytes" do
      # Pre-fix: C launcher left input_pipe[1] open after optional stdin, so
      # programs that read until EOF (cat) hung until timeout. Candidate sends
      # initial stdin then close-stdin so the child sees EOF and exits normally.
      payload = "exact-eof-payload-bytes\n"

      {:ok, result} = Executor.run("cat", stdin: payload, timeout: 2_000)

      assert result.exit_code == 0
      assert result.timed_out == false
      assert result.killed == false
      assert result.stdout == payload
    end

    test "one-shot closes stdin even when stdin is nil" do
      # Nil stdin must still close the write end; otherwise cat blocks forever.
      {:ok, result} = Executor.run("cat", timeout: 2_000)

      assert result.exit_code == 0
      assert result.timed_out == false
      assert result.killed == false
      assert result.stdout == ""
    end

    test "one-shot execute_direct closes stdin for EOF readers" do
      payload = "direct-argv-eof\n"

      {:ok, result} =
        Shell.execute_direct("cat", [], stdin: payload, timeout: 2_000, sandbox: :none)

      assert result.exit_code == 0
      assert result.timed_out == false
      assert result.stdout == payload
    end

    test "handles timeout" do
      {:ok, result} = Executor.run("sleep 10", timeout: 100)

      assert result.timed_out == true
      assert result.killed == true
      assert result.exit_code == 137
      assert result.output_limit_exceeded == false
      assert result.output_truncated == false
    end

    test "security regression: timeout 0 does not instantly kill short commands" do
      # LLM optional-arg footgun: timeout: 0 is truthy in Elixir and used to
      # make receive after 0 fire immediately → exit 137 on even `echo`.
      {:ok, result} = Executor.run("echo ok", timeout: 0)

      assert result.timed_out == false
      assert result.killed == false
      assert result.exit_code == 0
      assert result.stdout =~ "ok"
    end

    test "returns error when port open fails" do
      # Passing an invalid port option type causes Port.open to raise
      # We test this by using a command that Erlang can't spawn
      result = Executor.run("", cwd: "/dev/null/impossible/path")

      case result do
        {:error, _reason} -> :ok
        {:ok, %{exit_code: code}} when code != 0 -> :ok
      end
    end
  end

  describe "security regression: absolute timeout and output bounds" do
    # These proofs intentionally exceed typical "fast" unit budgets when the
    # absolute-timeout path is broken (outer Task.yield ~2s). Not :fast.
    @moduletag fast: false

    test "security regression: public Shell absolute timeout kills continuous finite output" do
      # Pre-fix: each stdout chunk reset `receive after timeout`, so a sync
      # call on a frequent producer never hits the absolute deadline until the
      # producer ends (~600ms here) with timed_out=false — assertion fails.
      # Candidate kills near the absolute deadline (~100ms). Outer Task.yield
      # is only a safety net; Task.shutdown cleans the BEAM owner if needed.
      # Producer is finite so any orphaned OS shell still exits on its own.
      outer_bound_ms = 1_500

      task =
        Task.async(fn ->
          Shell.execute(@finite_noisy_cmd, timeout: 100, sandbox: :none)
        end)

      case Task.yield(task, outer_bound_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, result}} ->
          assert result.timed_out == true
          assert result.killed == true
          assert result.output_limit_exceeded == false
          assert result.exit_code == 137
          assert result.duration_ms < outer_bound_ms

        {:ok, other} ->
          flunk("unexpected Shell.execute result: #{inspect(other)}")

        nil ->
          flunk(
            "Shell.execute did not return within #{outer_bound_ms}ms — absolute timeout failed (pre-fix continuous output reset receive-after)"
          )
      end
    end

    test "security regression: public Shell max_output_bytes kills and blocks delayed side effect" do
      # Pre-fix: all port output was retained unbounded and Port.close alone
      # could leave the OS process running after the output burst. Post-fix:
      # when a chunk would exceed the ceiling the process is SIGKILL'd so a
      # delayed filesystem side effect after the burst does not occur.
      tmp = System.tmp_dir!()
      marker = Path.join(tmp, "arbor_shell_out_limit_#{System.unique_integer([:positive])}")
      _ = File.rm(marker)

      on_exit(fn -> _ = File.rm(marker) end)

      # Finite burst large enough to exceed 256 bytes, then a short delayed
      # side effect. Keep sleeps short but long enough to observe post-kill.
      cmd =
        ~s{sh -c 'i=0; while [ "$i" -lt 5000 ]; do printf "%s\\n" "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"; i=$((i+1)); done; sleep 0.4; touch "#{marker}"'}

      {:ok, result} =
        Shell.execute(cmd,
          sandbox: :none,
          max_output_bytes: 256,
          timeout: 10_000
        )

      assert result.killed == true
      assert result.timed_out == false
      assert result.output_limit_exceeded == true
      assert result.output_truncated == true
      assert result.exit_code == 137
      assert byte_size(result.stdout) <= 256
      assert byte_size(result.stdout) > 0

      Process.sleep(600)
      refute File.exists?(marker), "producer continued after output limit; marker was written"
    end

    test "security regression: run and run_direct share absolute timeout under continuous finite output" do
      outer_bound_ms = 1_500

      for runner <- [
            fn -> Executor.run(@finite_noisy_cmd, timeout: 100) end,
            fn ->
              Executor.run_direct("python3", ["-c", @finite_noisy_python], timeout: 100)
            end
          ] do
        task = Task.async(runner)

        case Task.yield(task, outer_bound_ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, {:ok, result}} ->
            assert result.timed_out == true
            assert result.killed == true
            assert result.output_limit_exceeded == false
            assert result.exit_code == 137
            assert result.duration_ms < outer_bound_ms

          {:ok, other} ->
            flunk("unexpected runner result: #{inspect(other)}")

          nil ->
            flunk("runner did not return within #{outer_bound_ms}ms — absolute timeout failed")
        end
      end
    end

    test "security regression: run and run_direct share output-limit would-exceed semantics" do
      # Limit fires when retained output would *exceed* the ceiling; exactly
      # max_output_bytes is allowed and returned truncated only on overflow.
      # Finite producers: enough bytes to cross 128, then exit.
      burst = ~s{i=0; while [ "$i" -lt 200 ]; do printf "xxxxxxxx"; i=$((i+1)); done}

      for runner <- [
            fn opts -> Executor.run("sh -c '#{burst}'", opts) end,
            fn opts -> Executor.run_direct("sh", ["-c", burst], opts) end
          ] do
        {:ok, result} = runner.(max_output_bytes: 128, timeout: 5_000)

        assert result.output_limit_exceeded == true
        assert result.output_truncated == true
        assert result.killed == true
        assert result.timed_out == false
        assert byte_size(result.stdout) <= 128
        assert byte_size(result.stdout) > 0
      end

      # Exactly at the ceiling must complete normally (would-exceed, not equal).
      payload = String.duplicate("x", 64)

      {:ok, exact} =
        Executor.run_direct("printf", ["%s", payload],
          max_output_bytes: 64,
          timeout: 5_000
        )

      assert exact.output_limit_exceeded == false
      assert exact.output_truncated == false
      assert exact.killed == false
      assert exact.timed_out == false
      assert exact.exit_code == 0
      assert byte_size(exact.stdout) == 64
    end

    test "security regression: invalid max_output_bytes falls back to default via public Shell" do
      for bad <- [0, -1, nil, "big"] do
        {:ok, result} =
          Shell.execute("echo ok", sandbox: :none, max_output_bytes: bad, timeout: 5_000)

        assert result.exit_code == 0
        assert result.stdout =~ "ok"
        assert result.output_limit_exceeded == false
      end
    end

    test "security regression: max_output_bytes hard maximum clamps oversized values" do
      # Default 8 MiB; system hard max 16 MiB — larger positive requests must
      # not bypass retention bounds (normalize down, do not reject). Public
      # facade and Executor share one source of truth.
      default = 8_388_608
      hard_max = 16_777_216

      assert Shell.max_output_bytes_limit() == hard_max
      assert Shell.normalize_max_output_bytes(nil) == default
      assert Shell.normalize_max_output_bytes(0) == default
      assert Shell.normalize_max_output_bytes(-1) == default
      assert Shell.normalize_max_output_bytes("big") == default
      assert Shell.normalize_max_output_bytes(1) == 1
      assert Shell.normalize_max_output_bytes(default) == default
      assert Shell.normalize_max_output_bytes(hard_max) == hard_max
      assert Shell.normalize_max_output_bytes(hard_max + 1) == hard_max
      assert Shell.normalize_max_output_bytes(hard_max * 4) == hard_max

      # Executor seam stays in lockstep with the facade.
      assert Executor.normalize_max_output_bytes(hard_max * 2) ==
               Shell.normalize_max_output_bytes(hard_max * 2)
    end

    test "security regression: kill/limit does not leak late port messages into caller mailbox" do
      # Drain must be absolute-bounded; after a forced kill the caller mailbox
      # must be clean of port messages.
      burst = ~s{i=0; while [ "$i" -lt 200 ]; do printf "xxxxxxxx"; i=$((i+1)); done}

      {:ok, result} =
        Executor.run_direct("sh", ["-c", burst],
          max_output_bytes: 64,
          timeout: 5_000
        )

      assert result.output_limit_exceeded == true

      # Wait longer than the executor's absolute port-drain grace so any
      # race-in driver messages would have arrived by now.
      receive do
        {port, msg} when is_port(port) ->
          flunk("stale port message leaked after kill: #{inspect(msg)}")

        {:EXIT, port, reason} when is_port(port) ->
          flunk("stale port EXIT leaked after kill: #{inspect(reason)}")
      after
        250 -> :ok
      end
    end

    test "security regression: output limit truncation preserves valid UTF-8 prefix" do
      # "日" is 3 UTF-8 bytes. A ceiling that is not a multiple of 3 can cut
      # mid-codepoint; stdout is typed String.t and must remain valid for
      # JSON/checkpoint consumers.
      payload = String.duplicate("日", 40)
      assert byte_size(payload) == 120

      {:ok, result} =
        Executor.run_direct("printf", ["%s", payload],
          max_output_bytes: 10,
          timeout: 5_000
        )

      assert result.output_limit_exceeded == true
      assert result.output_truncated == true
      assert byte_size(result.stdout) <= 10
      assert String.valid?(result.stdout)
      # Complete 3-byte codepoints only (no mid-codepoint tail).
      assert rem(byte_size(result.stdout), 3) == 0
      assert result.stdout == String.duplicate("日", div(byte_size(result.stdout), 3))
    end

    test "security regression: async/public registry records :killed for output-limit termination" do
      # Output-limit must complete as :killed (terminal), not hang get_result
      # as :pending/:completed with a missing result.
      burst =
        ~s{sh -c 'i=0; while [ "$i" -lt 5000 ]; do printf "%s\\n" "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"; i=$((i+1)); done'}

      {:ok, exec_id} =
        Shell.execute_async(burst,
          sandbox: :none,
          max_output_bytes: 128,
          timeout: 10_000
        )

      {:ok, result} = Shell.get_result(exec_id, wait: true, timeout: 5_000)

      assert result.output_limit_exceeded == true
      assert result.output_truncated == true
      assert result.killed == true
      assert result.timed_out == false
      assert result.exit_code == 137
      assert byte_size(result.stdout) <= 128

      {:ok, status} = Shell.get_status(exec_id)
      assert status == :killed

      # Non-wait path must also treat :killed as terminal.
      assert {:ok, ^result} = Shell.get_result(exec_id)
    end
  end

  describe "security regression: process-group containment" do
    @moduletag fast: false

    test "timeout kills a delayed plain-shell descendant before returning" do
      marker =
        Path.join(System.tmp_dir!(), "shell_timeout_child_#{System.unique_integer([:positive])}")

      launched = marker <> ".launched"
      File.rm(marker)
      File.rm(launched)

      on_exit(fn ->
        File.rm(marker)
        File.rm(launched)
      end)

      script = ": > #{launched}; (sleep 0.5; touch #{marker}) & sleep 5"

      assert {:ok, result} = Executor.run_direct("sh", ["-c", script], timeout: 150)

      if darwin?() do
        assert result.exit_code != 0
        refute result.timed_out
        refute result.killed
      else
        assert result.timed_out
        assert result.killed
      end

      assert File.exists?(launched)
      Process.sleep(700)
      refute File.exists?(marker), "plain descendant survived timeout return"
    end

    test "output limit kills a configured Git helper tree before returning" do
      root = Path.join(System.tmp_dir!(), "git_helper_tree_#{System.unique_integer([:positive])}")
      marker = Path.join(root, "delayed-marker")
      launched = Path.join(root, "helper-launched")
      helper = Path.join(root, "diff-helper")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      System.cmd("git", ["init", "-q"], cd: root)
      System.cmd("git", ["config", "user.email", "test@example.com"], cd: root)
      System.cmd("git", ["config", "user.name", "Test"], cd: root)
      File.write!(Path.join(root, "tracked"), "one\n")
      System.cmd("git", ["add", "--", "tracked"], cd: root)
      System.cmd("git", ["commit", "-qm", "initial"], cd: root)
      File.write!(Path.join(root, "tracked"), "two\n")

      File.write!(helper, """
      #!/bin/sh
      touch #{launched}
      (sleep 0.6; touch #{marker}) &
      i=0
      while [ "$i" -lt 5000 ]; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n'; i=$((i+1)); done
      """)

      File.chmod!(helper, 0o755)
      System.cmd("git", ["config", "diff.external", helper], cd: root)

      assert {:ok, result} =
               Executor.run_direct("git", ["diff", "--ext-diff"],
                 cwd: root,
                 max_output_bytes: 256,
                 timeout: 5_000
               )

      if darwin?() do
        assert result.exit_code != 0
        refute result.output_limit_exceeded
        refute result.killed
        refute File.exists?(launched)
      else
        assert result.output_limit_exceeded
        assert result.killed
        assert File.exists?(launched)
      end

      Process.sleep(800)
      refute File.exists?(marker), "Git helper descendant survived output-limit return"
    end

    test "timeout kills a delayed Git hook tree before returning" do
      root = Path.join(System.tmp_dir!(), "git_hook_tree_#{System.unique_integer([:positive])}")
      marker = Path.join(root, "hook-delayed-marker")
      launched = Path.join(root, "hook-launched")
      hook = Path.join([root, ".git", "hooks", "pre-commit"])
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      System.cmd("git", ["init", "-q"], cd: root)
      System.cmd("git", ["config", "user.email", "test@example.com"], cd: root)
      System.cmd("git", ["config", "user.name", "Test"], cd: root)
      File.write!(Path.join(root, "tracked"), "content")
      System.cmd("git", ["add", "--", "tracked"], cd: root)

      File.write!(hook, "#!/bin/sh\ntouch '#{launched}'\nsleep 1.5\ntouch '#{marker}'\n")
      File.chmod!(hook, 0o755)

      assert {:ok, result} =
               Executor.run_direct("git", ["commit", "-m", "contained hook"],
                 cwd: root,
                 timeout: 500
               )

      if darwin?() do
        assert result.exit_code != 0
        refute result.timed_out
        refute result.killed
        refute File.exists?(launched)
      else
        assert result.timed_out
        assert File.exists?(launched)
      end

      Process.sleep(1_700)
      refute File.exists?(marker), "Git hook descendant survived timeout return"
    end

    test "async cancellation kills a delayed argv descendant before returning" do
      marker =
        Path.join(System.tmp_dir!(), "shell_cancel_child_#{System.unique_integer([:positive])}")

      launched = marker <> ".launched"
      File.rm(marker)
      File.rm(launched)

      on_exit(fn ->
        File.rm(marker)
        File.rm(launched)
      end)

      command = "sh -c ': > #{launched}; (sleep 0.6; touch #{marker}) & sleep 5'"
      assert {:ok, execution_id} = Shell.execute_async(command, sandbox: :none, timeout: 5_000)
      assert eventually?(fn -> File.exists?(launched) end, 1_000)

      if darwin?() do
        assert eventually?(
                 fn ->
                   match?(
                     {:ok, %{exit_code: code}} when code != 0,
                     Shell.get_result(execution_id)
                   )
                 end,
                 1_000
               )

        assert {:ok, result} = Shell.get_result(execution_id)
        assert result.exit_code != 0
        refute result.killed
      else
        assert :ok = Shell.kill(execution_id)
        assert {:ok, %{cancelled: true, killed: true}} = Shell.get_result(execution_id)
      end

      Process.sleep(800)
      refute File.exists?(marker), "argv descendant survived cancellation return"
    end
  end

  defp eventually?(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(20)
        do_eventually(fun, deadline)
    end
  end

  defp darwin?, do: match?({:unix, :darwin}, :os.type())
end
