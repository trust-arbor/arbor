defmodule Arbor.Actions.SessionGoalsPrincipalBindingSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions.SessionGoals

  @moduletag :fast

  # Agent-authored exec nodes can select pipeline_internal actions. The
  # executor/facade binds context.agent_id; node params cannot override it.
  for action <- [
        SessionGoals.UpdateGoals,
        SessionGoals.StoreDecompositions,
        SessionGoals.ProcessProposalDecisions,
        SessionGoals.StoreIdentity,
        SessionGoals.PruneStaleIntents
      ] do
    test "security regression: #{inspect(action)} refuses another agent's target" do
      for params <- [
            %{agent_id: "agent_victim"},
            %{"agent_id" => "agent_victim"},
            %{"session.agent_id" => "agent_victim"}
          ] do
        assert_raise ArgumentError, ~r/principal_mismatch/, fn ->
          unquote(action).run(params, %{agent_id: "agent_attacker"})
        end
      end
    end
  end

  test "security regression: cross-principal goal creation leaves the real victim store unchanged" do
    victim = "agent_goal_victim_#{System.unique_integer([:positive])}"
    assert Arbor.Memory.get_active_goals(victim) == []

    assert_raise ArgumentError, ~r/principal_mismatch/, fn ->
      SessionGoals.UpdateGoals.run(
        %{agent_id: victim, new_goals: [%{description: "Injected goal"}]},
        %{agent_id: "agent_attacker"}
      )
    end

    assert Arbor.Memory.get_active_goals(victim) == []
  end

  test "the real goal store accepts the bound principal's own goal" do
    principal = "agent_goal_owner_#{System.unique_integer([:positive])}"

    assert {:ok, %{goals_updated: true}} =
             SessionGoals.UpdateGoals.run(
               %{agent_id: principal, new_goals: [%{description: "Own goal"}]},
               %{agent_id: principal}
             )

    assert [%{description: "Own goal"}] = Arbor.Memory.get_active_goals(principal)
  end

  test "a missing params target uses the bound principal" do
    assert {:ok, %{goals_updated: true}} =
             SessionGoals.UpdateGoals.run(%{}, %{agent_id: "agent_self"})
  end

  test "direct in-VM calls retain the accepted params fallback" do
    assert {:ok, %{goals_updated: true}} =
             SessionGoals.UpdateGoals.run(%{agent_id: "agent_direct"}, %{})
  end
end
