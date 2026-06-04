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
      context =
        ctx(
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

    test "switch model with runtime= produces 3-tuple action with runtime opt" do
      assert {:ok, %Result{text: text, action: {:switch_model, "claude-opus-4-6", opts}}} =
               Model.execute("claude-opus-4-6 runtime=acp", ctx(agent_id: "agent_test"))

      assert Keyword.get(opts, :runtime) == :acp
      assert String.contains?(text, "claude-opus-4-6")
      assert String.contains?(text, "acp")
    end

    test "switch model with runtime=arbor works (default runtime explicitly)" do
      assert {:ok, %Result{action: {:switch_model, "claude-opus-4-6", opts}}} =
               Model.execute("claude-opus-4-6 runtime=arbor", ctx(agent_id: "agent_test"))

      assert Keyword.get(opts, :runtime) == :arbor
    end

    test "runtime= with no model points the user at /runtime" do
      assert {:ok, %Result{text: text, type: :error}} =
               Model.execute("runtime=acp", ctx(agent_id: "agent_test"))

      assert String.contains?(text, "/runtime")
    end

    test "unknown runtime value returns error with valid options" do
      assert {:ok, %Result{text: text, type: :error}} =
               Model.execute("claude-opus-4-6 runtime=garbage", ctx(agent_id: "agent_test"))

      assert String.contains?(text, "Unknown runtime")
      assert String.contains?(text, "arbor")
      assert String.contains?(text, "acp")
    end

    test "unrelated kwargs are silently skipped" do
      # Future-compat: unknown kwarg tokens don't break parse.
      assert {:ok, %Result{action: {:switch_model, "claude-opus-4-6", _opts}}} =
               Model.execute(
                 "claude-opus-4-6 future_arg=42 runtime=acp",
                 ctx(agent_id: "agent_test")
               )
    end
  end

  describe "Runtime" do
    alias Arbor.Common.Commands.Runtime

    test "shows current runtime when context has one" do
      context = ctx(agent_id: "agent_test") |> Map.put(:runtime, :acp)
      assert {:ok, %Result{text: text}} = Runtime.execute("", context)
      assert String.contains?(text, "acp")
    end

    test "shows default when no runtime in context" do
      context = ctx(agent_id: "agent_test")
      assert {:ok, %Result{text: text}} = Runtime.execute("", context)
      assert String.contains?(text, "arbor") and String.contains?(text, "default")
    end

    test "switch to acp returns action" do
      assert {:ok, %Result{action: {:switch_runtime, :acp}}} =
               Runtime.execute("acp", ctx(agent_id: "agent_test"))
    end

    test "switch to arbor returns action" do
      assert {:ok, %Result{action: {:switch_runtime, :arbor}}} =
               Runtime.execute("arbor", ctx(agent_id: "agent_test"))
    end

    test "case-insensitive runtime parse" do
      assert {:ok, %Result{action: {:switch_runtime, :acp}}} =
               Runtime.execute("ACP", ctx(agent_id: "agent_test"))
    end

    test "unknown runtime returns error" do
      assert {:ok, %Result{text: text, type: :error}} =
               Runtime.execute("garbage", ctx(agent_id: "agent_test"))

      assert String.contains?(text, "Unknown runtime")
    end

    test "switch without agent context errors" do
      assert {:ok, %Result{text: text, type: :error}} = Runtime.execute("acp", ctx())
      assert String.contains?(text, "Cannot") or String.contains?(text, "no current agent")
    end

    test "available?/1 requires an agent" do
      refute Runtime.available?(ctx())
      assert Runtime.available?(ctx(agent_id: "agent_test"))
    end
  end

  describe "Start" do
    alias Arbor.Common.Commands.Start

    test "available?/1 is true regardless of agent (always startable)" do
      assert Start.available?(ctx())
      assert Start.available?(ctx(agent_id: "agent_test"))
    end

    test "empty args returns usage error" do
      assert {:ok, %Result{text: text, type: :error}} = Start.execute("", ctx())
      assert String.contains?(text, "Usage:")
      assert String.contains?(text, "/start")
    end

    test "template only emits start_agent action with no opts" do
      assert {:ok, %Result{text: text, action: {:start_agent, "fizzbuzz", []}}} =
               Start.execute("fizzbuzz", ctx())

      assert String.contains?(text, "fizzbuzz")
    end

    test "template + name= kwarg parses into opts" do
      assert {:ok, %Result{action: {:start_agent, "fizzbuzz", opts}}} =
               Start.execute("fizzbuzz name=Foo", ctx())

      assert Keyword.get(opts, :name) == "Foo"
    end

    test "template + model= and runtime= kwargs both parse" do
      assert {:ok, %Result{action: {:start_agent, "fizzbuzz", opts}}} =
               Start.execute("fizzbuzz model=claude-opus-4-6 runtime=acp", ctx())

      assert Keyword.get(opts, :model) == "claude-opus-4-6"
      assert Keyword.get(opts, :runtime) == :acp
    end

    test "unknown runtime errors with valid options" do
      assert {:ok, %Result{text: text, type: :error}} =
               Start.execute("fizzbuzz runtime=garbage", ctx())

      assert String.contains?(text, "Unknown runtime")
    end

    test "unrelated kwargs silently skip (future-compat)" do
      assert {:ok, %Result{action: {:start_agent, "fizzbuzz", opts}}} =
               Start.execute("fizzbuzz future_arg=42 name=Foo", ctx())

      assert Keyword.get(opts, :name) == "Foo"
      refute Keyword.has_key?(opts, :future_arg)
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
      context =
        ctx(
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
