defmodule Arbor.Common.CommandsTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  describe "Help" do
    alias Arbor.Common.Commands.Help

    test "lists commands" do
      Arbor.Common.CommandRouter.refresh()
      assert {:ok, text} = Help.execute("", %{})
      assert String.contains?(text, "Available commands")
      assert String.contains?(text, "/help")
    end

    test "shows detail for specific command" do
      Arbor.Common.CommandRouter.refresh()
      assert {:ok, text} = Help.execute("status", %{})
      assert String.contains?(text, "/status")
    end

    test "shows unknown for invalid command" do
      Arbor.Common.CommandRouter.refresh()
      assert {:ok, text} = Help.execute("nonexistent999", %{})
      assert String.contains?(text, "Unknown command")
    end
  end

  describe "Status" do
    alias Arbor.Common.Commands.Status

    test "shows agent info from context" do
      context = %{
        agent_id: "agent_abc",
        display_name: "TestBot",
        model: "anthropic/claude-sonnet-4",
        provider: "anthropic"
      }

      assert {:ok, text} = Status.execute("", context)
      assert String.contains?(text, "TestBot")
      assert String.contains?(text, "anthropic/claude-sonnet-4")
      assert String.contains?(text, "anthropic")
    end

    test "handles missing context gracefully" do
      assert {:ok, text} = Status.execute("", %{})
      assert String.contains?(text, "none")
    end
  end

  describe "Model" do
    alias Arbor.Common.Commands.Model

    test "shows current model" do
      context = %{model: "anthropic/claude-sonnet-4", provider: "anthropic"}
      assert {:ok, text} = Model.execute("", context)
      assert String.contains?(text, "anthropic/claude-sonnet-4")
    end

    test "no model set" do
      assert {:ok, text} = Model.execute("", %{})
      assert String.contains?(text, "not set")
    end

    test "switch model via callback" do
      context = %{switch_model_fn: fn _m -> :ok end}
      assert {:ok, text} = Model.execute("gpt-4o", context)
      assert String.contains?(text, "Switched to model: gpt-4o")
    end

    test "switch model without callback" do
      assert {:ok, text} = Model.execute("gpt-4o", %{})
      assert String.contains?(text, "Restart the agent")
    end

    test "list models via callback" do
      context = %{list_models_fn: fn -> ["model-a", "model-b"] end}
      assert {:ok, text} = Model.execute("list", context)
      assert String.contains?(text, "model-a")
      assert String.contains?(text, "model-b")
    end
  end

  describe "Compact" do
    alias Arbor.Common.Commands.Compact

    test "requires session" do
      refute Compact.available?(%{})
      assert Compact.available?(%{session_pid: self()})
    end

    test "calls compact callback" do
      context = %{session_pid: self(), compact_fn: fn -> :ok end}
      assert {:ok, text} = Compact.execute("", context)
      assert String.contains?(text, "compacted")
    end

    test "shows stats" do
      stats = %{messages_before: 100, messages_after: 40, compression_ratio: 0.6}
      context = %{session_pid: self(), compact_fn: fn -> {:ok, stats} end}
      assert {:ok, text} = Compact.execute("", context)
      assert String.contains?(text, "60.0%")
    end
  end

  describe "Tools" do
    alias Arbor.Common.Commands.Tools

    test "lists tools from context" do
      tools = [
        %{name: "shell_exec", description: "Execute shell commands"},
        %{name: "file_read", description: "Read a file"}
      ]

      assert {:ok, text} = Tools.execute("", %{tools: tools})
      assert String.contains?(text, "shell_exec")
      assert String.contains?(text, "file_read")
    end

    test "finds tools by query" do
      tools = [
        %{name: "shell_exec", description: "Execute shell commands"},
        %{name: "file_read", description: "Read a file"}
      ]

      assert {:ok, text} = Tools.execute("find shell", %{tools: tools})
      assert String.contains?(text, "shell_exec")
      refute String.contains?(text, "file_read")
    end

    test "no tools" do
      assert {:ok, text} = Tools.execute("", %{})
      assert String.contains?(text, "No tools")
    end
  end

  describe "Session" do
    alias Arbor.Common.Commands.Session

    test "shows session info" do
      context = %{
        session_id: "sess_123",
        turn_count: 5,
        model: "anthropic/claude-sonnet-4",
        session_pid: self()
      }

      assert {:ok, text} = Session.execute("", context)
      assert String.contains?(text, "sess_123")
      assert String.contains?(text, "5")
    end
  end

  describe "Trust" do
    alias Arbor.Common.Commands.Trust

    test "shows trust tier" do
      assert {:ok, text} = Trust.execute("", %{trust_tier: "full_partner"})
      assert String.contains?(text, "full_partner")
    end

    test "shows profile rules" do
      profile = %{
        rules: [
          %{uri_prefix: "arbor://shell/", mode: :allow},
          %{uri_prefix: "arbor://code/", mode: :ask}
        ]
      }

      assert {:ok, text} = Trust.execute("", %{trust_profile: profile})
      assert String.contains?(text, "arbor://shell/")
      assert String.contains?(text, "allow")
    end
  end

  describe "Memory" do
    alias Arbor.Common.Commands.Memory

    test "calls memory callback" do
      context = %{memory_fn: fn -> {:ok, "3 thoughts, 1 concern"} end}
      assert {:ok, text} = Memory.execute("", context)
      assert String.contains?(text, "3 thoughts")
    end

    test "no memory available" do
      assert {:ok, text} = Memory.execute("", %{})
      assert String.contains?(text, "not available")
    end
  end
end
