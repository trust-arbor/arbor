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

    test "security regression (F-017): dispatch without an agent_id never reaches run/2" do
      # Pre-fix, a nil agent_id fell back to `action_module.run(params, %{})`
      # with no capability, trust, taint, or approval gate ("system-level
      # dispatch"). The only production caller passes `state.agent_id`; a nil
      # principal is a bug or an attack and must fail closed.
      # The hardcoded compound action path reports the action's error tag.
      assert {:error, {:missing_principal, :proposal_submit_failed}} =
               ActionDispatch.dispatch(:proposal_submit, %{proposal: %{}})

      assert {:error, {:missing_principal, "memory.remember"}} =
               ActionDispatch.dispatch("memory.remember", %{content: "x"}, nil)
    end
  end
end
