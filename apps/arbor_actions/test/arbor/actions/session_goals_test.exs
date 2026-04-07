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

    test "dedupes duplicate descriptions WITHIN a single new_goals batch (regression)" do
      # Regression for the diagnostician runaway loop. Previous version of
      # add_new_goals/4 used Enum.each with a snapshot of existing descriptions,
      # so identical descriptions in the same `new_goals` list all passed the
      # dedup check. Now uses Enum.reduce threading the seen-set, so within-
      # batch duplicates are caught.
      ensure_goal_store()
      agent_id = "test_dedup_within_batch_#{System.unique_integer([:positive])}"
      goal_store = Arbor.Memory.GoalStore
      on_exit(fn ->
        try do
          goal_store.clear_goals(agent_id)
        rescue
          _ -> :ok
        end
      end)

      # Sanity: agent starts with no goals
      assert goal_store.get_active_goals(agent_id) == []

      # Send a batch with three duplicates of the same description and one unique
      duplicate = "Set up automated alerting for threshold breaches"

      assert {:ok, _} =
               SessionGoals.UpdateGoals.run(
                 %{
                   agent_id: agent_id,
                   new_goals: [
                     %{"description" => duplicate},
                     %{"description" => duplicate},
                     %{"description" => duplicate},
                     %{"description" => "Different goal"}
                   ]
                 },
                 %{}
               )

      goals = goal_store.get_active_goals(agent_id)
      assert length(goals) == 2

      descriptions = goals |> Enum.map(& &1.description) |> Enum.sort()
      assert descriptions == ["Different goal", duplicate]
    end

    test "dedupes new_goals against existing goals (case-insensitive, trimmed)" do
      ensure_goal_store()
      agent_id = "test_dedup_existing_#{System.unique_integer([:positive])}"
      goal_store = Arbor.Memory.GoalStore
      on_exit(fn ->
        try do
          goal_store.clear_goals(agent_id)
        rescue
          _ -> :ok
        end
      end)

      # Pre-existing goal
      {:ok, _} = goal_store.add_goal(agent_id, "Diagnose system state")

      # Send "duplicates" with different casing/whitespace
      assert {:ok, _} =
               SessionGoals.UpdateGoals.run(
                 %{
                   agent_id: agent_id,
                   new_goals: [
                     %{"description" => "DIAGNOSE SYSTEM STATE"},
                     %{"description" => "  diagnose system state  "},
                     %{"description" => "Diagnose system state"}
                   ]
                 },
                 %{}
               )

      goals = goal_store.get_active_goals(agent_id)
      assert length(goals) == 1
    end
  end

  # Start the GoalStore GenServer if it's not already running. arbor_actions
  # tests don't start the arbor_memory application by default, so we need to
  # bring it up manually for the dedup tests that depend on the real store.
  defp ensure_goal_store do
    case Process.whereis(Arbor.Memory.GoalStore) do
      nil ->
        # Start unlinked so it survives the test process that first spawned it
        # (other async tests may still need it).
        spawn(fn ->
          {:ok, _} = Arbor.Memory.GoalStore.start_link([])
          Process.sleep(:infinity)
        end)

        wait_for_goal_store()

      _pid ->
        :ok
    end
  end

  defp wait_for_goal_store(retries \\ 50) do
    cond do
      Process.whereis(Arbor.Memory.GoalStore) != nil -> :ok
      retries == 0 -> raise "GoalStore failed to start"
      true ->
        Process.sleep(10)
        wait_for_goal_store(retries - 1)
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
