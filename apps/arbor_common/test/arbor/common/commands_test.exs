defmodule Arbor.Common.CommandsTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Commands.{Context, Result}

  @moduletag :fast

  defp ctx(attrs \\ []) do
    Context.new(Keyword.put_new(attrs, :origin, :test))
  end

  # Note on Session side-effect testing
  # ─────────────────────────────────────
  # The /model, /runtime, and /start commands perform side effects via
  # runtime-bridged Module.concat calls to Arbor.Orchestrator.Session
  # and Arbor.Agent.Manager. In arbor_common's isolated test env those
  # modules aren't loaded (arbor_common is Level 0.5 and can't compile-
  # time-depend on Level 2), so Code.ensure_loaded? returns false and
  # the commands surface "Cannot switch X: <Mod> module not loaded."
  #
  # These tests pin the failure-mode reachability — confirms parsing
  # succeeded and the command routed to the side-effect attempt.
  # Happy-path integration verification lives in arbor_dashboard's
  # chat_live_test.exs and arbor_orchestrator's session_test.exs
  # where the full module set is loaded.

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

    test "switch model with session_pid reaches side-effect attempt" do
      pid = spawn(fn -> :timer.sleep(:infinity) end)

      assert {:ok, %Result{type: :error, text: text}} =
               Model.execute("gpt-4o", ctx(agent_id: "agent_test", session_pid: pid))

      # Past parse stage; side effect couldn't load Session module.
      refute String.contains?(text, "Unknown runtime")
      assert String.contains?(text, "Session module not loaded")
    end

    test "switch model without agent explains limitation" do
      assert {:ok, %Result{text: text}} = Model.execute("gpt-4o", ctx())
      assert String.contains?(text, "no current agent") or String.contains?(text, "Cannot")
    end

    test "switch model + runtime: both args parse cleanly" do
      pid = spawn(fn -> :timer.sleep(:infinity) end)

      assert {:ok, %Result{type: :error, text: text}} =
               Model.execute(
                 "claude-opus-4-6 runtime=acp",
                 ctx(agent_id: "agent_test", session_pid: pid)
               )

      refute String.contains?(text, "Unknown runtime")
      assert String.contains?(text, "Session module not loaded")
    end

    test "switch model with runtime=arbor parses (explicit default)" do
      pid = spawn(fn -> :timer.sleep(:infinity) end)

      assert {:ok, %Result{type: :error, text: text}} =
               Model.execute(
                 "claude-opus-4-6 runtime=arbor",
                 ctx(agent_id: "agent_test", session_pid: pid)
               )

      refute String.contains?(text, "Unknown runtime")
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
      pid = spawn(fn -> :timer.sleep(:infinity) end)

      assert {:ok, %Result{type: :error, text: text}} =
               Model.execute(
                 "claude-opus-4-6 future_arg=42 runtime=acp",
                 ctx(agent_id: "agent_test", session_pid: pid)
               )

      refute String.contains?(text, "Unknown")
      assert String.contains?(text, "Session module not loaded")
    end

    test "missing session_pid in context surfaces error (forward-compat)" do
      assert {:ok, %Result{type: :error, text: text}} =
               Model.execute("gpt-4o", ctx(agent_id: "agent_test"))

      assert String.contains?(text, "session pid")
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

    test "switch to acp reaches side-effect attempt" do
      pid = spawn(fn -> :timer.sleep(:infinity) end)

      assert {:ok, %Result{type: :error, text: text}} =
               Runtime.execute("acp", ctx(agent_id: "agent_test", session_pid: pid))

      refute String.contains?(text, "Unknown runtime")
      assert String.contains?(text, "Session module not loaded")
    end

    test "switch to arbor reaches side-effect attempt" do
      pid = spawn(fn -> :timer.sleep(:infinity) end)

      assert {:ok, %Result{type: :error, text: text}} =
               Runtime.execute("arbor", ctx(agent_id: "agent_test", session_pid: pid))

      refute String.contains?(text, "Unknown runtime")
    end

    test "case-insensitive runtime parse" do
      pid = spawn(fn -> :timer.sleep(:infinity) end)

      assert {:ok, %Result{type: :error, text: text}} =
               Runtime.execute("ACP", ctx(agent_id: "agent_test", session_pid: pid))

      refute String.contains?(text, "Unknown runtime")
      assert String.contains?(text, "Session module not loaded")
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

    test "empty args returns usage error (parse-stage)" do
      assert {:ok, %Result{text: text, type: :error}} = Start.execute("", ctx())
      assert String.contains?(text, "Usage:")
      assert String.contains?(text, "/start")
    end

    test "unknown runtime errors at parse stage" do
      assert {:ok, %Result{text: text, type: :error}} =
               Start.execute("fizzbuzz runtime=garbage", ctx())

      assert String.contains?(text, "Unknown runtime")
    end

    # The parsing-success path now performs a side effect via
    # Arbor.Agent.Manager.start_or_resume/3, which requires the agent
    # supervision tree to be running. Unit tests can't easily spin that
    # up — these tests pin the failure-mode reachability: parsing
    # succeeded (no "Usage:" / "Unknown runtime" prefix), but the side
    # effect surfaces an error from Manager. Integration verification
    # of the happy path lives alongside the actual agent supervisor
    # boot.

    test "template + valid args reach the side-effect stage" do
      assert {:ok, %Result{type: :error, text: text}} =
               Start.execute("fizzbuzz name=Foo runtime=arbor", ctx())

      refute String.contains?(text, "Usage:")
      refute String.contains?(text, "Unknown runtime")
      # Side effect attempted; Manager module not loaded in arbor_common
      # test env (correct per hierarchy — arbor_common can't depend on
      # arbor_agent). Either error message proves dispatch reached the
      # side-effect stage.
      assert String.contains?(text, "/start failed:") or
               String.contains?(text, "Manager module not loaded")
    end

    test "unrelated kwargs silently skip — parse still succeeds" do
      # Future-compat: unknown kwarg tokens don't break parse. The
      # side effect still fails (no Manager loaded) but the failure
      # is past the parse stage.
      assert {:ok, %Result{type: :error, text: text}} =
               Start.execute("fizzbuzz future_arg=42 name=Foo", ctx())

      refute String.contains?(text, "Unknown")

      assert String.contains?(text, "/start failed:") or
               String.contains?(text, "Manager module not loaded")
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
