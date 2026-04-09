defmodule Arbor.Common.CommandRouterTest do
  use ExUnit.Case, async: true

  alias Arbor.Common.CommandRouter
  alias Arbor.Contracts.Commands.{Context, Result}

  @moduletag :fast

  # Helper: empty agent-less context (matches arbor_comms / "no current agent" mode).
  defp no_agent_ctx, do: Context.new(origin: :test, user_id: "tester")

  # Helper: full agent-bound context (matches dashboard mode).
  defp agent_ctx do
    Context.new(
      origin: :test,
      user_id: "tester",
      agent_id: "agent_test",
      session_id: "test-session",
      session_pid: self(),
      display_name: "Test Agent",
      model: "gpt-5",
      provider: :openai,
      trust_tier: :veteran,
      turn_count: 1,
      tools: ["foo"]
    )
  end

  describe "parse/1" do
    test "recognizes simple command" do
      assert {:command, "help", ""} = CommandRouter.parse("/help")
    end

    test "recognizes command with arguments" do
      assert {:command, "model", "anthropic/claude-sonnet-4"} =
               CommandRouter.parse("/model anthropic/claude-sonnet-4")
    end

    test "recognizes command with multi-word arguments" do
      assert {:command, "tools", "find shell"} =
               CommandRouter.parse("/tools find shell")
    end

    test "downcases command name" do
      assert {:command, "help", ""} = CommandRouter.parse("/HELP")
      assert {:command, "model", "Foo"} = CommandRouter.parse("/Model Foo")
    end

    test "trims argument whitespace" do
      assert {:command, "model", "foo"} = CommandRouter.parse("/model   foo  ")
    end

    test "slash alone is a prompt" do
      assert {:prompt, "/"} = CommandRouter.parse("/")
    end

    test "slash followed by space is a prompt" do
      assert {:prompt, "/ something"} = CommandRouter.parse("/ something")
    end

    test "normal text is a prompt" do
      assert {:prompt, "hello world"} = CommandRouter.parse("hello world")
    end

    test "empty string is a prompt" do
      assert {:prompt, ""} = CommandRouter.parse("")
    end

    test "slash followed by non-word char is a prompt" do
      assert {:prompt, "/!foo"} = CommandRouter.parse("/!foo")
    end
  end

  describe "execute/3" do
    setup do
      CommandRouter.refresh()
      :ok
    end

    test "executes a known display command and returns a typed Result" do
      assert {:ok, %Result{} = result} = CommandRouter.execute("help", "", agent_ctx())
      assert result.type == :info
      assert result.action == nil
      assert String.contains?(result.text, "Available commands")
    end

    test "returns error for unknown command" do
      assert {:error, {:unknown_command, msg}} =
               CommandRouter.execute("zzzzunknown", "", agent_ctx())

      assert String.contains?(msg, "Unknown command")
    end

    test "suggests similar command" do
      assert {:error, {:unknown_command, msg}} =
               CommandRouter.execute("hel", "", agent_ctx())

      assert String.contains?(msg, "Did you mean /help?")
    end

    test "returns unavailable for agent-bound commands when no current agent" do
      # /compact requires a session_pid; no_agent_ctx has none
      assert {:error, {:unavailable, _}} =
               CommandRouter.execute("compact", "", no_agent_ctx())
    end

    test "/clear returns an action: :clear Result" do
      assert {:ok, %Result{type: :command_action, action: :clear}} =
               CommandRouter.execute("clear", "", agent_ctx())
    end

    test "/compact returns an action: :compact Result" do
      assert {:ok, %Result{type: :command_action, action: :compact}} =
               CommandRouter.execute("compact", "", agent_ctx())
    end

    test "/model X returns an action: {:switch_model, name} Result" do
      assert {:ok, %Result{type: :command_action, action: {:switch_model, "gpt-6"}}} =
               CommandRouter.execute("model", "gpt-6", agent_ctx())
    end

    test "/model with no args returns display Result with current model" do
      assert {:ok, %Result{type: :info, action: nil, text: text}} =
               CommandRouter.execute("model", "", agent_ctx())

      assert String.contains?(text, "gpt-5")
    end

    test "rejects plain map context (Context struct required)" do
      # FunctionClauseError because the function head pattern-matches on
      # %Context{} — passing a plain map fails before any logic runs.
      assert_raise FunctionClauseError, fn ->
        CommandRouter.execute("help", "", %{})
      end
    end
  end

  describe "list_commands/1" do
    setup do
      CommandRouter.refresh()
      :ok
    end

    test "returns list of available commands as {name, desc, usage} tuples" do
      commands = CommandRouter.list_commands(agent_ctx())
      assert is_list(commands)
      assert length(commands) > 0

      assert Enum.all?(commands, fn {n, d, u} ->
               is_binary(n) and is_binary(d) and is_binary(u)
             end)
    end

    test "help is always in the list, even without an agent" do
      commands = CommandRouter.list_commands(no_agent_ctx())
      names = Enum.map(commands, &elem(&1, 0))
      assert "help" in names
    end

    test "agent-bound commands hidden in no-agent context" do
      commands = CommandRouter.list_commands(no_agent_ctx())
      names = Enum.map(commands, &elem(&1, 0))
      refute "compact" in names
      refute "clear" in names
      refute "status" in names
      refute "model" in names
      refute "tools" in names
    end

    test "agent-bound commands visible with full agent context" do
      commands = CommandRouter.list_commands(agent_ctx())
      names = Enum.map(commands, &elem(&1, 0))
      assert "compact" in names
      assert "clear" in names
      assert "status" in names
      assert "model" in names
      assert "tools" in names
    end
  end

  describe "aliases" do
    setup do
      CommandRouter.refresh()
      :ok
    end

    test "help accessible via h" do
      assert {:ok, %Result{text: text}} = CommandRouter.execute("h", "", agent_ctx())
      assert String.contains?(text, "Available commands")
    end

    test "help accessible via ?" do
      assert {:ok, %Result{text: text}} = CommandRouter.execute("?", "", agent_ctx())
      assert String.contains?(text, "Available commands")
    end

    test "memory accessible via mem" do
      assert {:ok, %Result{}} = CommandRouter.execute("mem", "", agent_ctx())
    end
  end
end
