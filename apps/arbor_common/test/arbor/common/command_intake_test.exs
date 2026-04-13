defmodule Arbor.Common.CommandIntakeTest do
  use ExUnit.Case, async: true

  alias Arbor.Common.CommandIntake
  alias Arbor.Contracts.Commands.{Context, Result}

  @moduletag :fast

  defp ctx do
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

  defp no_agent_ctx, do: Context.new(origin: :test, user_id: "tester")

  describe "handle/3 — prompt path (non-command)" do
    test "regular text invokes the fallback function with the original input" do
      result = CommandIntake.handle("hello world", ctx(), fn text -> {:fallback, text} end)
      assert result == {:fallback, "hello world"}
    end

    test "empty string invokes the fallback function" do
      result = CommandIntake.handle("", ctx(), fn text -> {:fallback, text} end)
      assert result == {:fallback, ""}
    end

    test "slash followed by space passes through as a prompt to fallback" do
      result = CommandIntake.handle("/ this is text", ctx(), fn text -> {:fallback, text} end)
      assert result == {:fallback, "/ this is text"}
    end

    test "slash with non-word character passes through as a prompt" do
      result = CommandIntake.handle("/!foo", ctx(), fn text -> {:fallback, text} end)
      assert result == {:fallback, "/!foo"}
    end

    test "fallback's return value is forwarded unchanged" do
      result = CommandIntake.handle("anything", ctx(), fn _ -> :totally_arbitrary end)
      assert result == :totally_arbitrary
    end
  end

  describe "handle/3 — command path (display commands)" do
    test "display command returns {:command_result, %Result{}} with type :info" do
      result = CommandIntake.handle("/help", ctx(), fn _ -> :unreachable end)

      assert {:command_result, %Result{type: :info, action: nil, text: text}} = result
      assert String.contains?(text, "Available commands")
    end

    test "/status returns the agent's display info" do
      result = CommandIntake.handle("/status", ctx(), fn _ -> :unreachable end)
      assert {:command_result, %Result{type: :info, action: nil, text: text}} = result
      assert String.contains?(text, "Test Agent")
      assert String.contains?(text, "gpt-5")
    end

    test "fallback is NOT invoked when input is a command" do
      _ =
        CommandIntake.handle("/help", ctx(), fn _ ->
          flunk("fallback should not be called for commands")
        end)
    end
  end

  describe "handle/3 — command path (action commands)" do
    test "/clear returns a Result with action: :clear" do
      result = CommandIntake.handle("/clear", ctx(), fn _ -> :unreachable end)

      assert {:command_result, %Result{type: :command_action, action: :clear, text: text}} =
               result

      assert String.contains?(text, "cleared")
    end

    test "/compact returns a Result with action: :compact" do
      result = CommandIntake.handle("/compact", ctx(), fn _ -> :unreachable end)
      assert {:command_result, %Result{action: :compact}} = result
    end

    test "/model X returns a Result with action: {:switch_model, name}" do
      result =
        CommandIntake.handle("/model anthropic/claude-opus-4-6", ctx(), fn _ -> :unreachable end)

      assert {:command_result, %Result{action: {:switch_model, "anthropic/claude-opus-4-6"}}} =
               result
    end
  end

  describe "handle/3 — error paths" do
    test "unknown command returns {:command_error, message}" do
      result = CommandIntake.handle("/zzznotreal", ctx(), fn _ -> :unreachable end)

      assert {:command_error, msg} = result
      assert String.contains?(msg, "Unknown command")
    end

    test "unknown command suggestion is included when name is similar" do
      result = CommandIntake.handle("/hel", ctx(), fn _ -> :unreachable end)
      assert {:command_error, msg} = result
      assert String.contains?(msg, "Did you mean /help?")
    end

    test "agent-bound command in no-agent context returns :command_error" do
      result = CommandIntake.handle("/clear", no_agent_ctx(), fn _ -> :unreachable end)
      assert {:command_error, msg} = result
      assert String.contains?(msg, "not available")
    end

    test "/status without an agent returns :command_error" do
      result = CommandIntake.handle("/status", no_agent_ctx(), fn _ -> :unreachable end)
      assert {:command_error, _msg} = result
    end
  end

  describe "classify/1" do
    test "returns parse output without executing" do
      assert {:command, "help", ""} = CommandIntake.classify("/help")
      assert {:command, "model", "gpt-5"} = CommandIntake.classify("/model gpt-5")
      assert {:prompt, "hello"} = CommandIntake.classify("hello")
      assert {:prompt, "/ space"} = CommandIntake.classify("/ space")
    end
  end

  describe "multi-channel parity (regression for the arbor_comms bifurcation)" do
    # The CRC refactor (2026-04-09) eliminated the bifurcation between
    # dashboard and arbor_comms slash command handling. Both now go through
    # CommandIntake. This test asserts that the SAME input + DIFFERENT origin
    # contexts produce consistent shapes — only the visibility differs.
    test "agent context: full command list available" do
      ctx_dashboard = %{ctx() | origin: :dashboard}
      result = CommandIntake.handle("/help", ctx_dashboard, fn _ -> :unreachable end)
      assert {:command_result, %Result{text: text}} = result
      # Should list all 9 commands
      for cmd <- ~w(help status session model trust memory tools clear compact) do
        assert String.contains?(text, "/#{cmd}"),
               "expected /#{cmd} to appear in dashboard /help output"
      end
    end

    test "no-agent context (arbor_comms style): only system commands available" do
      ctx_comms = %{no_agent_ctx() | origin: :arbor_comms}
      result = CommandIntake.handle("/help", ctx_comms, fn _ -> :unreachable end)
      assert {:command_result, %Result{text: text}} = result
      assert String.contains?(text, "/help")
      # Agent-bound commands MUST NOT appear in the no-agent listing
      refute String.contains?(text, "/clear")
      refute String.contains?(text, "/compact")
      refute String.contains?(text, "/status")
      refute String.contains?(text, "/model")
    end
  end
end
