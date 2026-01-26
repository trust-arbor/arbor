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
    end
  end
end
