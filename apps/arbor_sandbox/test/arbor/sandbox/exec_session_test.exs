defmodule Arbor.Sandbox.ExecSessionTest do
  use ExUnit.Case, async: true

  alias Arbor.Sandbox.ExecSession

  describe "basic evaluation" do
    test "evaluates simple arithmetic" do
      {:ok, pid} = ExecSession.start_link(agent_id: "test-agent")
      assert {:ok, "2"} = ExecSession.eval(pid, "1 + 1")
    end

    test "evaluates string operations" do
      {:ok, pid} = ExecSession.start_link(agent_id: "test-agent")
      assert {:ok, "\"HELLO\""} = ExecSession.eval(pid, "String.upcase(\"hello\")")
    end

    test "evaluates list operations" do
      {:ok, pid} = ExecSession.start_link(agent_id: "test-agent")
      assert {:ok, "[1, 2, 3]"} = ExecSession.eval(pid, "Enum.sort([3, 1, 2])")
    end
  end

  describe "state persistence" do
    test "variable bindings persist across evaluations" do
      {:ok, pid} = ExecSession.start_link(agent_id: "test-agent")
      assert {:ok, "42"} = ExecSession.eval(pid, "x = 42")
      assert {:ok, "43"} = ExecSession.eval(pid, "x + 1")
    end

    test "multiple variables persist" do
      {:ok, pid} = ExecSession.start_link(agent_id: "test-agent")
      assert {:ok, "10"} = ExecSession.eval(pid, "a = 10")
      assert {:ok, "20"} = ExecSession.eval(pid, "b = 20")
      assert {:ok, "30"} = ExecSession.eval(pid, "a + b")
    end

    test "failed evaluation preserves prior state" do
      {:ok, pid} = ExecSession.start_link(agent_id: "test-agent")
      assert {:ok, "42"} = ExecSession.eval(pid, "x = 42")
      # Division by zero fails
      assert {:error, _} = ExecSession.eval(pid, "x / 0")
      # x should still be available
      assert {:ok, "42"} = ExecSession.eval(pid, "x")
    end
  end

  describe "reset" do
    test "clears all bindings" do
      {:ok, pid} = ExecSession.start_link(agent_id: "test-agent")
      assert {:ok, "42"} = ExecSession.eval(pid, "x = 42")
      assert :ok = ExecSession.reset(pid)
      # x should no longer be defined
      assert {:error, _} = ExecSession.eval(pid, "x")
    end

    test "resets execution count" do
      {:ok, pid} = ExecSession.start_link(agent_id: "test-agent")
      ExecSession.eval(pid, "1 + 1")
      ExecSession.eval(pid, "2 + 2")
      assert %{execution_count: 2} = ExecSession.stats(pid)
      ExecSession.reset(pid)
      assert %{execution_count: 0} = ExecSession.stats(pid)
    end
  end

  describe "safety restrictions" do
    test "blocks File module access" do
      {:ok, pid} = ExecSession.start_link(agent_id: "test-agent")
      assert {:error, message} = ExecSession.eval(pid, "File.read!(\"/etc/passwd\")")
      assert message =~ "restricted"
    end

    test "blocks System module access" do
      {:ok, pid} = ExecSession.start_link(agent_id: "test-agent")
      assert {:error, message} = ExecSession.eval(pid, "System.cmd(\"ls\", [])")
      assert message =~ "restricted"
    end

    test "blocks Process module access" do
      {:ok, pid} = ExecSession.start_link(agent_id: "test-agent")
      assert {:error, message} = ExecSession.eval(pid, "Process.exit(self(), :kill)")
      assert message =~ "restricted"
    end

    test "enforces memory limits" do
      {:ok, pid} = ExecSession.start_link(agent_id: "test-agent", max_heap_size: 1_000)
      assert {:error, message} = ExecSession.eval(pid, "List.duplicate(:x, 100_000)")
      assert message =~ "memory"
    end

    test "enforces reduction limits" do
      {:ok, pid} = ExecSession.start_link(agent_id: "test-agent", max_reductions: 1_000)
      assert {:error, message} = ExecSession.eval(pid, "Enum.reduce(1..1_000_000, 0, &+/2)")
      assert message =~ "reductions"
    end
  end

  describe "stdout capture" do
    test "captures IO.puts output" do
      {:ok, pid} = ExecSession.start_link(agent_id: "test-agent")
      assert {:ok, ":ok", stdio} = ExecSession.eval(pid, "IO.puts(\"hello\")")
      assert stdio =~ "hello"
    end
  end

  describe "stats" do
    test "returns session statistics" do
      {:ok, pid} = ExecSession.start_link(agent_id: "test-agent")
      stats = ExecSession.stats(pid)

      assert stats.agent_id == "test-agent"
      assert stats.execution_count == 0
      assert is_integer(stats.uptime_seconds)
    end

    test "tracks execution count" do
      {:ok, pid} = ExecSession.start_link(agent_id: "test-agent")
      ExecSession.eval(pid, "1 + 1")
      ExecSession.eval(pid, "2 + 2")
      ExecSession.eval(pid, "3 + 3")

      assert %{execution_count: 3} = ExecSession.stats(pid)
    end

    test "counts failed evaluations" do
      {:ok, pid} = ExecSession.start_link(agent_id: "test-agent")
      ExecSession.eval(pid, "1 + 1")
      ExecSession.eval(pid, "1 / 0")

      assert %{execution_count: 2} = ExecSession.stats(pid)
    end
  end
end
