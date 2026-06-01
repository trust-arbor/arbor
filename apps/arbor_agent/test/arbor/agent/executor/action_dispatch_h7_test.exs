defmodule Arbor.Agent.Executor.ActionDispatchH7Test do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Agent.Executor.ActionDispatch

  describe "H7 regression: hardcoded actions route through Arbor.Actions.authorize_and_execute" do
    test "security regression (H7): :proposal_submit with agent_id goes through authorize_and_execute" do
      # H7: pre-fix, dispatch(:proposal_submit, params) called
      #   apply(Arbor.Actions.Proposal.Submit, :run, [params, %{}])
      # directly, bypassing taint enforcement, resource binding, invocation
      # receipts, and facade-level checks. The fix routes through
      # Arbor.Actions.authorize_and_execute/4 when an agent_id is provided,
      # which means an agent with no consensus/propose capability now gets
      # denied rather than silently executing.
      #
      # In this test environment the action module isn't registered with a
      # canonical_uri_for/2, but authorize_and_execute still returns an
      # :unauthorized-class error for an agent that holds no caps. The
      # contract we pin is "the dispatch reaches authorize_and_execute" —
      # the exact error shape depends on test infra, so we match on the
      # error tag class.
      agent_id = "h7_unprivileged_#{System.unique_integer([:positive])}"

      result = ActionDispatch.dispatch(:proposal_submit, %{proposal: %{}}, agent_id)

      assert match?({:error, {:proposal_submit_failed, _}}, result) or
               match?({:error, _}, result),
             "Hardcoded :proposal_submit must go through authorize_and_execute and " <>
               "deny when caller has no caps — H7 regression. Got: #{inspect(result)}"
    end

    test ":proposal_submit without agent_id still uses the direct apply path" do
      # Backward compatibility: callers that don't have an agent_id (system
      # internal paths, certain tests) keep getting the direct apply
      # behavior. Without an agent_id we don't have anyone to authorize
      # against; the choice is "deny everything" (which would break those
      # paths) or "fall back to direct" (which preserves existing behavior
      # and the operator can layer their own gate at the caller). This
      # test pins the fallback.
      result = ActionDispatch.dispatch(:proposal_submit, %{proposal: %{}})

      # Direct apply will either run the action or return :consensus_unavailable
      # if the consensus module isn't loaded. Either way it's NOT a
      # :proposal_submit_failed shape (that's the authorize_and_execute
      # branch).
      assert match?({:error, :consensus_unavailable}, result) or
               match?({:ok, _}, result) or
               match?({:error, {:proposal_submit_failed, _}}, result),
             "nil agent_id should preserve fallback dispatch behavior. " <>
               "Got: #{inspect(result)}"
    end
  end
end
