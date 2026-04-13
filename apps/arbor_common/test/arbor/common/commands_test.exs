defmodule Arbor.Common.CommandsTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Commands.{Context, Result}

  @moduletag :fast

  defp ctx(attrs \\ []) do
    Context.new(Keyword.put_new(attrs, :origin, :test))
  end

  describe "Help" do
    alias Arbor.Common.Commands.Help

    test "lists commands" do
      Arbor.Common.CommandRouter.refresh()
      assert {:ok, %Result{text: text}} = Help.execute("", ctx())
      assert String.contains?(text, "Available commands")
      assert String.contains?(text, "/help")
    end

    test "shows detail for specific command" do
      Arbor.Common.CommandRouter.refresh()
      assert {:ok, %Result{text: text}} = Help.execute("status", ctx())
      assert String.contains?(text, "/status")
    end

    test "shows unknown for invalid command" do
      Arbor.Common.CommandRouter.refresh()
      assert {:ok, %Result{text: text}} = Help.execute("nonexistent999", ctx())
      assert String.contains?(text, "Unknown command")
    end
  end

  describe "Status" do
    alias Arbor.Common.Commands.Status

    test "shows agent info from context" do
      context = ctx(
        agent_id: "agent_abc",
        display_name: "TestBot",
        model: "anthropic/claude-sonnet-4",
        provider: "anthropic"
      )

      assert {:ok, %Result{text: text}} = Status.execute("", context)
      assert String.contains?(text, "TestBot")
      assert String.contains?(text, "anthropic/claude-sonnet-4")
      assert String.contains?(text, "anthropic")
    end

    test "handles missing context gracefully" do
      assert {:ok, %Result{text: text}} = Status.execute("", ctx())
      # Should still produce some output without crashing
      assert is_binary(text) and text != ""
    end
  end

  describe "Model" do
    alias Arbor.Common.Commands.Model

    test "shows current model" do
      context = ctx(model: "anthropic/claude-sonnet-4", provider: "anthropic")
      assert {:ok, %Result{text: text}} = Model.execute("", context)
      assert String.contains?(text, "anthropic/claude-sonnet-4")
    end

    test "no model set" do
      assert {:ok, %Result{text: text}} = Model.execute("", ctx())
      assert String.contains?(text, "not set") or String.contains?(text, "No model")
    end

    test "switch model with agent returns action" do
      assert {:ok, %Result{text: text, action: {:switch_model, "gpt-4o"}}} =
               Model.execute("gpt-4o", ctx(agent_id: "agent_test"))
      assert String.contains?(text, "gpt-4o")
    end

    test "switch model without agent explains limitation" do
      assert {:ok, %Result{text: text}} = Model.execute("gpt-4o", ctx())
      assert String.contains?(text, "no current agent") or String.contains?(text, "Cannot")
    end
  end

  describe "Compact" do
    alias Arbor.Common.Commands.Compact

    test "requires session" do
      refute Compact.available?(ctx())
      assert Compact.available?(ctx(session_pid: self()))
    end

    test "returns compact action" do
      context = ctx(session_pid: self())
      assert {:ok, %Result{action: :compact}} = Compact.execute("", context)
    end
  end

  describe "Tools" do
    alias Arbor.Common.Commands.Tools

    test "lists tools from context" do
      tools = ["shell_exec", "file_read"]
      assert {:ok, %Result{text: text}} = Tools.execute("", ctx(tools: tools))
      assert String.contains?(text, "shell_exec")
      assert String.contains?(text, "file_read")
    end

    test "no tools" do
      assert {:ok, %Result{text: text}} = Tools.execute("", ctx())
      assert String.contains?(text, "No tools")
    end
  end

  describe "Session" do
    alias Arbor.Common.Commands.Session

    test "shows session info" do
      context = ctx(
        session_id: "sess_123",
        turn_count: 5,
        model: "anthropic/claude-sonnet-4",
        session_pid: self()
      )

      assert {:ok, %Result{text: text}} = Session.execute("", context)
      assert String.contains?(text, "sess_123")
      assert String.contains?(text, "5")
    end
  end

  describe "Trust" do
    alias Arbor.Common.Commands.Trust

    test "shows trust tier" do
      assert {:ok, %Result{text: text}} = Trust.execute("", ctx(trust_tier: :full_partner))
      assert String.contains?(text, "full_partner")
    end

    test "shows profile rules" do
      profile = %{
        rules: [
          %{uri_prefix: "arbor://shell/", mode: :allow},
          %{uri_prefix: "arbor://code/", mode: :ask}
        ]
      }

      assert {:ok, %Result{text: text}} = Trust.execute("", ctx(trust_profile: profile))
      assert String.contains?(text, "arbor://shell/")
      assert String.contains?(text, "allow")
    end
  end

  describe "Memory" do
    alias Arbor.Common.Commands.Memory

    test "no memory available" do
      assert {:ok, %Result{text: text}} = Memory.execute("", ctx())
      assert String.contains?(text, "not available") or String.contains?(text, "No")
    end
  end
end
