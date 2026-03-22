defmodule Arbor.Common.CommandRouterTest do
  use ExUnit.Case, async: true

  alias Arbor.Common.CommandRouter

  @moduletag :fast

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
    test "executes known command" do
      # Help command is always available
      CommandRouter.refresh()
      assert {:ok, text} = CommandRouter.execute("help", "", %{})
      assert String.contains?(text, "Available commands")
    end

    test "returns error for unknown command" do
      CommandRouter.refresh()
      assert {:error, {:unknown_command, msg}} = CommandRouter.execute("zzzzunknown", "", %{})
      assert String.contains?(msg, "Unknown command")
    end

    test "suggests similar command" do
      CommandRouter.refresh()
      assert {:error, {:unknown_command, msg}} = CommandRouter.execute("hel", "", %{})
      assert String.contains?(msg, "Did you mean /help?")
    end

    test "returns unavailable for gated commands" do
      CommandRouter.refresh()
      # Compact requires session_pid in context — without it, available? returns false
      assert {:error, {:unavailable, _}} = CommandRouter.execute("compact", "", %{})
    end
  end

  describe "list_commands/1" do
    test "returns list of available commands" do
      CommandRouter.refresh()
      commands = CommandRouter.list_commands(%{})
      assert is_list(commands)
      assert length(commands) > 0

      # Each entry is {name, description, usage}
      assert Enum.all?(commands, fn {n, d, u} ->
               is_binary(n) and is_binary(d) and is_binary(u)
             end)
    end

    test "help is always in the list" do
      CommandRouter.refresh()
      commands = CommandRouter.list_commands(%{})
      names = Enum.map(commands, &elem(&1, 0))
      assert "help" in names
    end

    test "session-only commands hidden without session" do
      CommandRouter.refresh()
      commands = CommandRouter.list_commands(%{})
      names = Enum.map(commands, &elem(&1, 0))
      refute "compact" in names
      refute "clear" in names
    end

    test "session-only commands visible with session" do
      CommandRouter.refresh()
      commands = CommandRouter.list_commands(%{session_pid: self()})
      names = Enum.map(commands, &elem(&1, 0))
      assert "compact" in names
      assert "clear" in names
    end
  end

  describe "aliases" do
    test "help accessible via h" do
      CommandRouter.refresh()
      assert {:ok, text} = CommandRouter.execute("h", "", %{})
      assert String.contains?(text, "Available commands")
    end

    test "help accessible via ?" do
      CommandRouter.refresh()
      assert {:ok, text} = CommandRouter.execute("?", "", %{})
      assert String.contains?(text, "Available commands")
    end

    test "memory accessible via mem" do
      CommandRouter.refresh()
      assert {:ok, _text} = CommandRouter.execute("mem", "", %{})
    end
  end
end
