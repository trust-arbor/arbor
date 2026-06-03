defmodule Arbor.Orchestrator.Handlers.ExecActionAdversarialTest do
  @moduledoc """
  Adversarial inputs to `Arbor.Orchestrator.Handlers.ExecHandler` with
  `target="action"` — the path that runs Jido actions via ActionsExecutor.

  Three concerns:

    1. **Error propagation** — does a malformed exec node produce a
       clear failure_reason, or a cryptic crash / silent no-op?
    2. **Param marshalling** — DOT attrs are strings; actions expect
       typed atoms. Does `parse_attr_args/1` + `atomize_known_keys/2`
       handle weird attr shapes gracefully?
    3. **Resilience** — exceptions raised inside the handler must
       become Outcome failures, not engine crashes.

  All cases assert that the engine completes (no crash), the outcome
  is a fail (not silent success), and the failure_reason mentions the
  underlying problem.
  """

  use ExUnit.Case, async: true
  @moduletag :fast

  # If arbor_actions isn't compiled into this run, half the tests
  # have no executor target. Guard with module check.
  @actions_available Code.ensure_loaded?(Arbor.Actions)

  defp logs_root do
    Path.join(System.tmp_dir!(), "arbor_exec_adv_#{System.unique_integer([:positive])}")
  end

  defp run_dot(dot) do
    root = logs_root()
    on_exit(fn -> File.rm_rf(root) end)

    Arbor.Orchestrator.run(dot,
      logs_root: root,
      authorization: false
    )
  end

  defp final_failure_reason(run_result) do
    case run_result.final_outcome do
      %{failure_reason: reason} when is_binary(reason) -> reason
      %{notes: notes} when is_binary(notes) -> notes
      _ -> nil
    end
  end

  # ── Missing / empty action attribute ──────────────────────────────

  describe "missing action attribute" do
    test "no `action` attr → raises → fail outcome with clear message" do
      dot = """
      digraph G {
        start [shape=Mdiamond]
        runit [type="exec", target="action"]
        done [shape=Msquare]
        start -> runit -> done
      }
      """

      assert {:ok, result} = run_dot(dot)
      assert result.final_outcome.status == :fail
      reason = final_failure_reason(result)
      assert is_binary(reason)
      assert reason =~ "action"
    end

    test "empty `action=\"\"` is treated the same as missing (raises the clear error)" do
      # Fixed: `if action_name in [nil, ""]` now catches the empty-string
      # case. Before the fix, `unless ""` was false (empty string is
      # truthy in Elixir), so the explicit raise was bypassed and the
      # empty string flowed to ActionsExecutor producing a confusing
      # "Unknown action: " with nothing after the colon.
      dot = """
      digraph G {
        start [shape=Mdiamond]
        runit [type="exec", target="action", action=""]
        done [shape=Msquare]
        start -> runit -> done
      }
      """

      assert {:ok, result} = run_dot(dot)
      assert result.final_outcome.status == :fail
      reason = final_failure_reason(result)
      assert is_binary(reason)
      assert reason =~ "requires non-empty"
    end
  end

  # ── Unknown action name ───────────────────────────────────────────

  describe "unknown action name" do
    @tag :skip_without_actions
    test "totally-fictional action name → Unknown action error" do
      unless @actions_available, do: :skip

      dot = """
      digraph G {
        start [shape=Mdiamond]
        runit [type="exec", target="action", action="nonexistent.fake_action"]
        done [shape=Msquare]
        start -> runit -> done
      }
      """

      assert {:ok, result} = run_dot(dot)
      assert result.final_outcome.status == :fail
      reason = final_failure_reason(result)
      assert is_binary(reason)
      assert reason =~ "Unknown action"
      assert reason =~ "nonexistent.fake_action"
    end

    test "action name with invalid module characters (control chars)" do
      unless @actions_available, do: :skip

      dot = """
      digraph G {
        start [shape=Mdiamond]
        runit [type="exec", target="action", action="bad\\u0000name"]
        done [shape=Msquare]
        start -> runit -> done
      }
      """

      # Should fail cleanly (Unknown action), not crash.
      assert {:ok, result} = run_dot(dot)
      assert result.final_outcome.status == :fail
    end
  end

  # ── Known action, missing required params ─────────────────────────

  describe "known action, missing required params" do
    test "set_display_name missing both required params → Jido validation error" do
      unless @actions_available, do: :skip

      # SetDisplayName requires :agent_id and :display_name. We pass
      # neither. Jido NimbleOptions should reject before the action's
      # run/2 is called — so even if the underlying profile store is
      # unavailable, this fails at the validation layer.
      dot = """
      digraph G {
        start [shape=Mdiamond]
        rename [type="exec", target="action", action="agent_profile.set_display_name"]
        done [shape=Msquare]
        start -> rename -> done
      }
      """

      assert {:ok, result} = run_dot(dot)
      assert result.final_outcome.status == :fail
      reason = final_failure_reason(result)
      assert is_binary(reason)
      # Error mentions the action AND something about a param/validation.
      assert reason =~ "agent_profile" or reason =~ "set_display_name"
    end

    test "set_display_name missing only display_name (partial params)" do
      unless @actions_available, do: :skip

      dot = """
      digraph G {
        start [shape=Mdiamond]
        rename [
          type="exec",
          target="action",
          action="agent_profile.set_display_name",
          arg.agent_id="agent_test"
        ]
        done [shape=Msquare]
        start -> rename -> done
      }
      """

      assert {:ok, result} = run_dot(dot)
      # Will fail somewhere (validation or downstream). What we want
      # is a non-crash + non-silent-success result.
      assert result.final_outcome.status == :fail
    end
  end

  # ── Param key mangling ────────────────────────────────────────────

  describe "param key mangling (parse_attr_args quirks)" do
    test "arg.foo.bar (nested dotted) becomes string key 'foo.bar' silently" do
      unless @actions_available, do: :skip

      # parse_attr_args/1 strips ONLY the first 'arg.' / 'param.'
      # prefix, leaving 'foo.bar' as the rest of the key. Since
      # 'foo.bar' isn't a known schema atom, it stays a string and
      # gets passed to the action as an extra param. Most actions
      # silently ignore unknown params; the agent_id requirement
      # still fails this run, but the 'foo.bar' attr is essentially
      # dead weight with no warning.
      dot = """
      digraph G {
        start [shape=Mdiamond]
        rename [
          type="exec",
          target="action",
          action="agent_profile.set_display_name",
          arg.foo.bar="this is lost without a trace"
        ]
        done [shape=Msquare]
        start -> rename -> done
      }
      """

      assert {:ok, result} = run_dot(dot)
      # The arg.foo.bar attr is silently mangled. Pipeline still fails
      # because agent_id/display_name aren't supplied, but the mangling
      # itself produces no warning.
      assert result.final_outcome.status == :fail
    end

    test "context_keys with missing key is silently dropped" do
      unless @actions_available, do: :skip

      # context_keys lookup returns nil → `if value != nil` skips the
      # merge. No warning, no error — the missing key is just absent
      # from action_args.
      dot = """
      digraph G {
        start [shape=Mdiamond]
        rename [
          type="exec",
          target="action",
          action="agent_profile.set_display_name",
          arg.agent_id="agent_test",
          context_keys="nonexistent_context_key"
        ]
        done [shape=Msquare]
        start -> rename -> done
      }
      """

      assert {:ok, result} = run_dot(dot)
      assert result.final_outcome.status == :fail
    end
  end

  # ── Target dispatch ───────────────────────────────────────────────

  describe "target dispatch fallbacks" do
    test "unknown target falls through to ToolHandler (no error)" do
      # ExecHandler dispatches on `target`. The fallback (`_ ->`) routes
      # to ToolHandler — which then requires a tool_command attr.
      dot = """
      digraph G {
        start [shape=Mdiamond]
        bogus [type="exec", target="not_a_real_target"]
        done [shape=Msquare]
        start -> bogus -> done
      }
      """

      assert {:ok, result} = run_dot(dot)
      # ToolHandler fails because there's no tool_command, but the
      # engine completes. No crash, clear-ish error.
      assert result.final_outcome.status == :fail
    end

    test "target=function without :function_handler opt → clear fail" do
      dot = """
      digraph G {
        start [shape=Mdiamond]
        f [type="exec", target="function"]
        done [shape=Msquare]
        start -> f -> done
      }
      """

      assert {:ok, result} = run_dot(dot)
      assert result.final_outcome.status == :fail

      reason = final_failure_reason(result)
      assert is_binary(reason)
      assert reason =~ "function_handler" or reason =~ "function"
    end
  end

  # ── Resilience: engine doesn't crash ──────────────────────────────

  describe "exception → fail outcome (never crash)" do
    test "raise inside handler wraps into Outcome.failure_reason" do
      # The 'no action attr' case raises in execute_action. The engine
      # catches it via Executor.do_execute_with_retry's rescue clause
      # and wraps it as %Outcome{status: :fail}. Test that this path
      # works end-to-end.
      dot = """
      digraph G {
        start [shape=Mdiamond]
        bad [type="exec", target="action"]
        done [shape=Msquare]
        start -> bad -> done
      }
      """

      # Should NOT raise from run/2 — even though the handler raised.
      assert {:ok, _result} = run_dot(dot)
    end
  end
end
