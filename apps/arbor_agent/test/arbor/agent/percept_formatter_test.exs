defmodule Arbor.Agent.PerceptFormatterTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.PerceptFormatter
  alias Arbor.Contracts.Memory.{Intent, Percept}

  defp make_intent(cap, op, target \\ nil) do
    Intent.capability_intent(cap, op, target || "/tmp/test", reasoning: "test")
  end

  describe "from_result/3 with success" do
    test "creates success percept" do
      intent = make_intent("fs", :read, "/etc/hosts")
      percept = PerceptFormatter.from_result(intent, {:ok, %{content: "hello"}}, 42)

      assert %Percept{} = percept
      assert percept.outcome == :success
      assert percept.duration_ms == 42
      assert percept.intent_id == intent.id
      assert is_binary(percept.summary)
    end

    test "summary includes capability and op" do
      intent = make_intent("fs", :read, "/etc/hosts")
      percept = PerceptFormatter.from_result(intent, {:ok, %{content: "hello"}}, 10)

      assert String.contains?(percept.summary, "fs.read")
    end

    test "summary includes target" do
      intent = make_intent("fs", :read, "/etc/hosts")
      percept = PerceptFormatter.from_result(intent, {:ok, %{content: "hello"}}, 10)

      assert String.contains?(percept.summary, "/etc/hosts")
    end

    test "extracts line count for fs.read" do
      intent = make_intent("fs", :read, "/etc/hosts")
      content = "line1\nline2\nline3\n"
      percept = PerceptFormatter.from_result(intent, {:ok, %{content: content}}, 10)

      assert String.contains?(percept.summary, "4 lines")
    end

    test "extracts match count for fs.glob" do
      intent = make_intent("fs", :glob, "*.ex")
      percept = PerceptFormatter.from_result(intent, {:ok, %{matches: ["a.ex", "b.ex"]}}, 10)

      assert String.contains?(percept.summary, "2 matches")
    end

    test "extracts exit code for shell" do
      intent = make_intent("shell", :execute, "ls")
      percept = PerceptFormatter.from_result(intent, {:ok, %{exit_code: 0}}, 100)

      assert String.contains?(percept.summary, "exit 0")
    end

    test "normalizes string result to map" do
      intent = make_intent("shell", :execute, "echo hello")
      percept = PerceptFormatter.from_result(intent, {:ok, "output"}, 10)

      assert percept.data == %{text: "output"}
    end

    test "normalizes list result to map" do
      intent = make_intent("fs", :list, "/tmp")
      percept = PerceptFormatter.from_result(intent, {:ok, ["a", "b"]}, 10)

      assert percept.data == %{items: ["a", "b"]}
    end
  end

  describe "from_result/3 with unauthorized error" do
    test "creates blocked percept" do
      intent = make_intent("shell", :execute, "rm -rf /")
      percept = PerceptFormatter.from_result(intent, {:error, :unauthorized}, 5)

      assert percept.outcome == :blocked
      assert String.contains?(percept.summary, "BLOCKED")
      assert String.contains?(percept.summary, "unauthorized")
    end
  end

  describe "from_result/3 with taint error" do
    test "creates blocked percept with taint details" do
      intent = make_intent("shell", :execute, "cmd")
      error = {:error, {:taint_blocked, :command, :hostile, :control}}
      percept = PerceptFormatter.from_result(intent, error, 5)

      assert percept.outcome == :blocked
      assert String.contains?(percept.summary, "BLOCKED")
      assert String.contains?(percept.summary, "taint")
    end
  end

  describe "from_result/3 with generic error" do
    test "creates failure percept" do
      intent = make_intent("fs", :read, "/nonexistent")
      percept = PerceptFormatter.from_result(intent, {:error, :enoent}, 10)

      assert percept.outcome == :failure
      assert String.contains?(percept.summary, "FAILED")
      assert String.contains?(percept.summary, "enoent")
    end

    test "sanitizes error strings" do
      intent = make_intent("code", :compile, "/project")
      long_error = String.duplicate("x", 1000)
      percept = PerceptFormatter.from_result(intent, {:error, long_error}, 10)

      # Error should be truncated
      assert String.length(percept.summary) < 300
    end
  end

  describe "timeout/2" do
    test "creates timeout percept" do
      intent = make_intent("shell", :execute, "slow-command")
      percept = PerceptFormatter.timeout(intent, 30_000)

      assert percept.outcome == :failure
      assert percept.type == :timeout
      assert String.contains?(percept.summary, "timed out")
      assert String.contains?(percept.summary, "30000ms")
    end
  end

  describe "from_mental_result/2" do
    test "creates success percept for mental action" do
      intent = make_intent("goal", :list)
      percept = PerceptFormatter.from_mental_result(intent, {:ok, %{goals: []}})

      assert percept.outcome == :success
      assert is_nil(percept.duration_ms)
    end

    test "creates failure percept for mental action" do
      intent = make_intent("compute", :run)
      percept = PerceptFormatter.from_mental_result(intent, {:error, :syntax_error})

      assert percept.outcome == :failure
      assert String.contains?(percept.summary, "FAILED")
    end
  end

  describe "data truncation" do
    test "truncates large string values" do
      intent = make_intent("fs", :read, "/big-file")
      big_content = String.duplicate("x", 10_000)
      percept = PerceptFormatter.from_result(intent, {:ok, %{content: big_content}}, 10)

      content = percept.data[:content] || percept.data["content"]

      if content do
        assert String.length(content) <= 5000
      end
    end

    test "truncates large lists" do
      intent = make_intent("fs", :list, "/")
      big_list = Enum.map(1..200, &"file_#{&1}")
      percept = PerceptFormatter.from_result(intent, {:ok, %{entries: big_list}}, 10)

      entries = percept.data[:entries] || percept.data["entries"]

      if entries do
        assert length(entries) <= 51
      end
    end
  end

  describe "edge cases" do
    test "handles intent without capability fields" do
      intent = Intent.action(:shell_execute, %{command: "ls"})
      percept = PerceptFormatter.from_result(intent, {:ok, %{exit_code: 0}}, 10)

      # Should not crash, falls back to action name
      assert percept.outcome == :success
    end

    test "handles nil target" do
      intent = make_intent("goal", :list, nil)
      percept = PerceptFormatter.from_result(intent, {:ok, %{goals: []}}, 0)

      assert percept.outcome == :success
      # No target in summary
      refute String.contains?(percept.summary, "nil")
    end
  end
end
