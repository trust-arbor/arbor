defmodule Arbor.ShellTest do
  use ExUnit.Case, async: true

  alias Arbor.Shell

  describe "execute/2" do
    test "executes simple command" do
      {:ok, result} = Shell.execute("echo hello", sandbox: :none)

      assert result.exit_code == 0
      assert String.trim(result.stdout) == "hello"
      assert result.timed_out == false
      assert result.killed == false
    end

    test "captures exit code" do
      {:ok, result} = Shell.execute("sh -c 'exit 42'", sandbox: :none)

      assert result.exit_code == 42
    end

    test "handles timeout" do
      {:ok, result} = Shell.execute("sleep 10", timeout: 100, sandbox: :none)

      assert result.timed_out == true
      assert result.killed == true
    end

    test "respects working directory" do
      {:ok, result} = Shell.execute("pwd", cwd: "/tmp", sandbox: :none)

      # macOS symlinks /tmp to /private/tmp
      assert String.trim(result.stdout) in ["/tmp", "/private/tmp"]
    end
  end

  describe "sandbox modes" do
    test "basic sandbox blocks dangerous commands" do
      {:error, {:blocked_command, "sudo"}} = Shell.execute("sudo ls", sandbox: :basic)
      {:error, {:blocked_command, "rm"}} = Shell.execute("rm -rf /", sandbox: :basic)
    end

    test "basic sandbox blocks dangerous flags" do
      {:error, {:dangerous_flags, ["-rf"]}} =
        Shell.execute("somecmd -rf /path", sandbox: :basic)
    end

    test "strict sandbox only allows allowlisted commands" do
      {:ok, _} = Shell.execute("echo hello", sandbox: :strict)
      {:error, {:not_in_allowlist, "curl"}} = Shell.execute("curl http://example.com", sandbox: :strict)
    end

    test "none sandbox allows everything" do
      # This would be dangerous in production, but tests run in isolation
      {:ok, _} = Shell.execute("echo dangerous", sandbox: :none)
    end
  end

  describe "execute_async/2" do
    test "returns execution ID" do
      {:ok, exec_id} = Shell.execute_async("echo async", sandbox: :none)

      assert is_binary(exec_id)
      assert String.starts_with?(exec_id, "exec_")
    end

    test "can get status" do
      {:ok, exec_id} = Shell.execute_async("echo test", sandbox: :none)

      # Give it a moment to complete
      Process.sleep(100)

      {:ok, status} = Shell.get_status(exec_id)
      assert status in [:running, :completed]
    end

    test "can get result" do
      {:ok, exec_id} = Shell.execute_async("echo async_result", sandbox: :none)

      {:ok, result} = Shell.get_result(exec_id, wait: true, timeout: 5000)

      assert result.exit_code == 0
      assert String.contains?(result.stdout, "async_result")
    end
  end

  describe "list_executions/1" do
    test "returns list of executions" do
      Shell.execute("echo list_test", sandbox: :none)

      {:ok, executions} = Shell.list_executions()

      assert is_list(executions)
    end

    test "filters by status" do
      Shell.execute("echo completed_test", sandbox: :none)

      {:ok, completed} = Shell.list_executions(status: :completed)

      assert Enum.all?(completed, &(&1.status == :completed))
    end
  end

  describe "get_status/1 edge cases" do
    test "returns not_found for unknown execution" do
      assert {:error, :not_found} = Shell.get_status("exec_nonexistent")
    end
  end

  describe "get_result/1 edge cases" do
    test "returns pending for running execution" do
      {:ok, exec_id} = Shell.execute_async("sleep 5", sandbox: :none)

      result = Shell.get_result(exec_id)
      assert {:pending, %{status: status}} = result
      assert status in [:pending, :running]

      # Cleanup: kill the sleeping process
      Shell.kill(exec_id)
    end

    test "returns not_found for unknown execution" do
      assert {:error, :not_found} = Shell.get_result("exec_nonexistent")
    end

    test "wait times out for slow commands" do
      {:ok, exec_id} = Shell.execute_async("sleep 10", sandbox: :none)

      assert {:error, :timeout} = Shell.get_result(exec_id, wait: true, timeout: 100)

      Shell.kill(exec_id)
    end
  end

  describe "kill/1" do
    test "returns not_running for completed execution" do
      {:ok, exec_id} = Shell.execute_async("echo done", sandbox: :none)
      Process.sleep(200)

      assert {:error, :not_running} = Shell.kill(exec_id)
    end

    test "returns not_found for unknown execution" do
      assert {:error, :not_found} = Shell.kill("exec_nonexistent")
    end
  end

  describe "long command truncation" do
    test "truncates very long commands in signals" do
      long_cmd = "echo " <> String.duplicate("x", 300)
      {:ok, result} = Shell.execute(long_cmd, sandbox: :none)
      assert result.exit_code == 0
    end
  end

  describe "healthy?/0" do
    test "returns true when system is running" do
      assert Shell.healthy?() == true
    end
  end

  describe "sandbox_config/1" do
    test "returns config for each level" do
      assert %{level: :none} = Shell.sandbox_config(:none)
      assert %{level: :basic, blocked_commands: cmds} = Shell.sandbox_config(:basic)
      assert is_list(cmds)
      assert %{level: :strict, allowlist: list} = Shell.sandbox_config(:strict)
      assert is_list(list)
      assert %{level: :container} = Shell.sandbox_config(:container)
    end
  end

  describe "sandbox container mode" do
    test "container mode returns not implemented" do
      assert {:error, :container_not_implemented} =
               Shell.execute("echo test", sandbox: :container)
    end
  end

  describe "get_result/2 immediate retrieval" do
    test "returns result immediately for completed sync execution" do
      {:ok, _result} = Shell.execute("echo immediate", sandbox: :none)

      # List executions to find the one we just created
      {:ok, executions} = Shell.list_executions(status: :completed)

      completed =
        Enum.find(executions, fn e ->
          e.command == "echo immediate" and e.status == :completed
        end)

      assert completed != nil

      # get_result without wait should return immediately
      {:ok, result} = Shell.get_result(completed.id)
      assert result.exit_code == 0
    end

    test "returns result for failed execution without wait" do
      {:ok, executions_before} = Shell.list_executions()
      before_ids = MapSet.new(Enum.map(executions_before, & &1.id))

      {:ok, _result} = Shell.execute("sh -c 'exit 1'", sandbox: :none)

      {:ok, executions_after} = Shell.list_executions()

      new_exec =
        Enum.find(executions_after, fn e ->
          not MapSet.member?(before_ids, e.id) and e.command == "sh -c 'exit 1'"
        end)

      assert new_exec != nil
      {:ok, result} = Shell.get_result(new_exec.id)
      assert result.exit_code == 1
    end
  end

  describe "execute_streaming/2" do
    test "returns session_id" do
      {:ok, session_id} = Shell.execute_streaming("echo streaming", stream_to: self(), sandbox: :none)
      assert is_binary(session_id)
      assert String.starts_with?(session_id, "port_")

      assert_receive {:port_exit, ^session_id, 0, output}, 5_000
      assert String.contains?(output, "streaming")
    end

    test "subscriber receives chunks then exit" do
      script = "sh -c 'echo chunk1; echo chunk2'"
      {:ok, session_id} = Shell.execute_streaming(script, stream_to: self(), sandbox: :none)

      assert_receive {:port_exit, ^session_id, 0, output}, 5_000
      assert String.contains?(output, "chunk1")
      assert String.contains?(output, "chunk2")
    end

    test "sandbox enforcement applies to streaming" do
      {:error, {:blocked_command, "sudo"}} =
        Shell.execute_streaming("sudo ls", stream_to: self(), sandbox: :basic)
    end
  end

  describe "stop_session/1" do
    test "stops a running streaming session" do
      {:ok, session_id} =
        Shell.execute_streaming("sleep 60", stream_to: self(), sandbox: :none, timeout: :infinity)

      assert :ok = Shell.stop_session(session_id)
    end

    test "returns not_found for unknown session" do
      assert {:error, :not_found} = Shell.stop_session("port_nonexistent")
    end
  end

  describe "executor edge cases" do
    test "handles command with environment variables" do
      {:ok, result} =
        Shell.execute("sh -c 'echo $MY_VAR'",
          sandbox: :none,
          env: %{"MY_VAR" => "arbor_test"}
        )

      assert String.trim(result.stdout) == "arbor_test"
    end

    test "handles command with stdin" do
      {:ok, result} =
        Shell.execute("cat",
          sandbox: :none,
          stdin: "hello from stdin",
          timeout: 2000
        )

      assert String.contains?(result.stdout, "hello from stdin")
    end

    test "handles invalid working directory" do
      # Invalid cwd results in either an error or a non-zero exit code
      result =
        Shell.execute("echo test",
          sandbox: :none,
          cwd: "/nonexistent/path/to/project"
        )

      case result do
        {:error, _reason} -> :ok
        {:ok, %{exit_code: code}} -> assert code != 0
      end
    end

    test "handles command-only input (no args) in basic sandbox" do
      {:ok, _result} = Shell.execute("date", sandbox: :basic)
    end
  end
end
