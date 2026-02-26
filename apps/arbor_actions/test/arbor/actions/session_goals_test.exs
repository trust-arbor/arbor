defmodule Arbor.Actions.SessionGoalsTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.SessionGoals

  @moduletag :fast

  # ============================================================================
  # UpdateGoals
  # ============================================================================

  describe "UpdateGoals — schema" do
    test "action metadata" do
      assert SessionGoals.UpdateGoals.name() == "session_goals_update"
    end

    test "requires agent_id" do
      assert {:error, _} = SessionGoals.UpdateGoals.validate_params(%{})
    end

    test "accepts valid params" do
      assert {:ok, _} =
               SessionGoals.UpdateGoals.validate_params(%{
                 agent_id: "agent_1",
                 goal_updates: [%{id: "g1", progress: 0.5}],
                 new_goals: [%{description: "test"}]
               })
    end
  end

  describe "UpdateGoals — run" do
    test "returns success even when facades unavailable" do
      assert {:ok, %{goals_updated: true}} =
               SessionGoals.UpdateGoals.run(
                 %{
                   agent_id: "test",
                   goal_updates: [%{"id" => "g1", "progress" => 0.5}],
                   new_goals: [%{"description" => "test goal"}]
                 },
                 %{}
               )
    end

    test "handles empty lists" do
      assert {:ok, %{goals_updated: true}} =
               SessionGoals.UpdateGoals.run(
                 %{agent_id: "test", goal_updates: [], new_goals: []},
                 %{}
               )
    end

    test "raises without agent_id" do
      assert_raise ArgumentError, ~r/agent_id/, fn ->
        SessionGoals.UpdateGoals.run(%{}, %{})
      end
    end

    test "accepts context key format" do
      assert {:ok, %{goals_updated: true}} =
               SessionGoals.UpdateGoals.run(
                 %{"session.agent_id" => "test", "session.new_goals" => []},
                 %{}
               )
    end
  end

  # ============================================================================
  # StoreDecompositions
  # ============================================================================

  describe "StoreDecompositions — schema" do
    test "action metadata" do
      assert SessionGoals.StoreDecompositions.name() == "session_goals_store_decomps"
    end

    test "requires agent_id" do
      assert {:error, _} = SessionGoals.StoreDecompositions.validate_params(%{})
    end
  end

  describe "StoreDecompositions — run" do
    test "returns success even when facades unavailable" do
      decomps = [
        %{
          "goal_id" => "g1",
          "intentions" => [
            %{"action" => "file.read", "description" => "Read the config"}
          ]
        }
      ]

      assert {:ok, %{decompositions_stored: true}} =
               SessionGoals.StoreDecompositions.run(
                 %{agent_id: "test", decompositions: decomps},
                 %{}
               )
    end

    test "handles empty decompositions" do
      assert {:ok, %{decompositions_stored: true}} =
               SessionGoals.StoreDecompositions.run(
                 %{agent_id: "test", decompositions: []},
                 %{}
               )
    end

    test "raises without agent_id" do
      assert_raise ArgumentError, ~r/agent_id/, fn ->
        SessionGoals.StoreDecompositions.run(%{}, %{})
      end
    end
  end

  # ============================================================================
  # ProcessProposalDecisions
  # ============================================================================

  describe "ProcessProposalDecisions — schema" do
    test "action metadata" do
      assert SessionGoals.ProcessProposalDecisions.name() == "session_goals_process_proposals"
    end

    test "requires agent_id" do
      assert {:error, _} = SessionGoals.ProcessProposalDecisions.validate_params(%{})
    end
  end

  describe "ProcessProposalDecisions — run" do
    test "returns success even when facades unavailable" do
      decisions = [
        %{"proposal_id" => "p1", "decision" => "accept"},
        %{"proposal_id" => "p2", "decision" => "reject", "reason" => "too risky"}
      ]

      assert {:ok, %{proposals_processed: true}} =
               SessionGoals.ProcessProposalDecisions.run(
                 %{agent_id: "test", decisions: decisions},
                 %{}
               )
    end

    test "handles defer decision (no-op)" do
      decisions = [%{"proposal_id" => "p1", "decision" => "defer"}]

      assert {:ok, %{proposals_processed: true}} =
               SessionGoals.ProcessProposalDecisions.run(
                 %{agent_id: "test", decisions: decisions},
                 %{}
               )
    end

    test "skips decisions without proposal_id" do
      decisions = [%{"decision" => "accept"}]

      assert {:ok, %{proposals_processed: true}} =
               SessionGoals.ProcessProposalDecisions.run(
                 %{agent_id: "test", decisions: decisions},
                 %{}
               )
    end

    test "raises without agent_id" do
      assert_raise ArgumentError, ~r/agent_id/, fn ->
        SessionGoals.ProcessProposalDecisions.run(%{}, %{})
      end
    end
  end

  # ============================================================================
  # StoreIdentity
  # ============================================================================

  describe "StoreIdentity — schema" do
    test "action metadata" do
      assert SessionGoals.StoreIdentity.name() == "session_goals_store_identity"
    end

    test "requires agent_id" do
      assert {:error, _} = SessionGoals.StoreIdentity.validate_params(%{})
    end
  end

  describe "StoreIdentity — run" do
    test "returns success even when facades unavailable" do
      insights = [
        %{"category" => "trait", "content" => "curious", "confidence" => 0.8}
      ]

      assert {:ok, %{identity_stored: true}} =
               SessionGoals.StoreIdentity.run(
                 %{agent_id: "test", insights: insights},
                 %{}
               )
    end

    test "handles empty insights" do
      assert {:ok, %{identity_stored: true}} =
               SessionGoals.StoreIdentity.run(
                 %{agent_id: "test", insights: []},
                 %{}
               )
    end

    test "skips insights missing category or content" do
      insights = [%{"category" => "trait"}, %{"content" => "curious"}]

      assert {:ok, %{identity_stored: true}} =
               SessionGoals.StoreIdentity.run(
                 %{agent_id: "test", insights: insights},
                 %{}
               )
    end

    test "raises without agent_id" do
      assert_raise ArgumentError, ~r/agent_id/, fn ->
        SessionGoals.StoreIdentity.run(%{}, %{})
      end
    end
  end
end
