defmodule Arbor.Shell.ExecutorTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Shell.Executor

  describe "run/2" do
    test "executes command and returns result" do
      {:ok, result} = Executor.run("echo executor_test")

      assert result.exit_code == 0
      assert String.contains?(result.stdout, "executor_test")
      assert result.timed_out == false
      assert result.killed == false
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

    test "handles timeout" do
      {:ok, result} = Executor.run("sleep 10", timeout: 100)

      assert result.timed_out == true
      assert result.killed == true
      assert result.exit_code == 137
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

  describe "kill_port/1" do
    test "closes an open port" do
      # Open a long-running port directly
      port = Port.open({:spawn, "sleep 30"}, [:binary, :exit_status])
      assert is_port(port)
      assert Port.info(port) != nil

      assert :ok = Executor.kill_port(port)
    end

    test "returns error for already-closed port" do
      port = Port.open({:spawn, "echo done"}, [:binary, :exit_status])
      # Wait for the command to finish and port to close
      Process.sleep(100)
      # Flush port messages
      receive do
        {^port, {:data, _}} -> :ok
      after
        0 -> :ok
      end

      receive do
        {^port, {:exit_status, _}} -> :ok
      after
        0 -> :ok
      end

      # Port should be closed now, kill_port should return error
      assert {:error, _reason} = Executor.kill_port(port)
    end
  end
end
