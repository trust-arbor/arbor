defmodule Arbor.Orchestrator.Session.HeartbeatProposalsTest do
  @moduledoc """
  Tests for Phase 3 heartbeat-to-proposals refactor.

  Verifies that apply_heartbeat_result/2 creates proposals instead of
  directly mutating session state.
  """

  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Session.Builders

  @moduletag :fast

  setup do
    # Ensure proposal ETS table exists
    if :ets.whereis(:arbor_memory_proposals) == :undefined do
      :ets.new(:arbor_memory_proposals, [:named_table, :public, :set])
    end

    agent_id = "hb_prop_test_#{System.unique_integer([:positive])}"

    state = %Arbor.Orchestrator.Session{
      session_id: "test-session",
      agent_id: agent_id,
      trust_tier: :established,
      turn_graph: nil,
      heartbeat_graph: nil,
      cognitive_mode: :reflection,
      goals: [%{"id" => "g1", "description" => "Existing goal", "progress" => 0.3}],
      messages: [],
      working_memory: %{},
      turn_count: 5
    }

    on_exit(fn ->
      if Code.ensure_loaded?(Arbor.Memory.Proposal) do
        Arbor.Memory.Proposal.delete_all(agent_id)
      end
    end)

    {:ok, state: state, agent_id: agent_id}
  end

  describe "apply_heartbeat_result/2 (Phase 3)" do
    test "returns state UNMODIFIED", %{state: state} do
      result = %{
        context: %{
          "session.cognitive_mode" => "goal_pursuit",
          "session.new_goals" => [%{"description" => "New goal"}],
          "session.goal_updates" => [],
          "session.memory_notes" => ["A thought"],
          "session.concerns" => [],
          "session.curiosity" => [],
          "session.identity_insights" => [],
          "session.decompositions" => []
        }
      }

      new_state = Builders.apply_heartbeat_result(state, result)

      # State should be UNCHANGED — no direct mutation
      assert new_state.cognitive_mode == :reflection
      assert new_state.goals == state.goals
    end

    test "creates proposals for cognitive mode changes", %{state: state, agent_id: agent_id} do
      result = %{
        context: %{
          "session.cognitive_mode" => "goal_pursuit",
          "session.new_goals" => [],
          "session.goal_updates" => [],
          "session.memory_notes" => [],
          "session.concerns" => [],
          "session.curiosity" => [],
          "session.identity_insights" => [],
          "session.decompositions" => []
        }
      }

      Builders.apply_heartbeat_result(state, result)

      if Code.ensure_loaded?(Arbor.Memory.Proposal) do
        {:ok, proposals} = Arbor.Memory.Proposal.list_pending(agent_id)
        mode_proposals = Enum.filter(proposals, &(&1.type == :cognitive_mode))
        assert mode_proposals != []
        assert hd(mode_proposals).content =~ "goal_pursuit"
      end
    end

    test "creates proposals for new goals", %{state: state, agent_id: agent_id} do
      result = %{
        context: %{
          "session.cognitive_mode" => "",
          "session.new_goals" => [
            %{"description" => "Learn Elixir", "type" => "achieve"},
            %{"description" => "Write tests", "type" => "maintain"}
          ],
          "session.goal_updates" => [],
          "session.memory_notes" => [],
          "session.concerns" => [],
          "session.curiosity" => [],
          "session.identity_insights" => [],
          "session.decompositions" => []
        }
      }

      Builders.apply_heartbeat_result(state, result)

      if Code.ensure_loaded?(Arbor.Memory.Proposal) do
        {:ok, proposals} = Arbor.Memory.Proposal.list_pending(agent_id)
        goal_proposals = Enum.filter(proposals, &(&1.type == :goal))
        assert length(goal_proposals) == 2
      end
    end

    test "creates proposals for thoughts/concerns/curiosity", %{state: state, agent_id: agent_id} do
      result = %{
        context: %{
          "session.cognitive_mode" => "",
          "session.new_goals" => [],
          "session.goal_updates" => [],
          "session.memory_notes" => ["Interesting observation", "Pattern noticed"],
          "session.concerns" => ["Memory growing"],
          "session.curiosity" => ["What is this?"],
          "session.identity_insights" => [],
          "session.decompositions" => []
        }
      }

      Builders.apply_heartbeat_result(state, result)

      if Code.ensure_loaded?(Arbor.Memory.Proposal) do
        {:ok, proposals} = Arbor.Memory.Proposal.list_pending(agent_id)

        thoughts = Enum.filter(proposals, &(&1.type == :thought))
        concerns = Enum.filter(proposals, &(&1.type == :concern))
        curiosities = Enum.filter(proposals, &(&1.type == :curiosity))

        assert length(thoughts) == 2
        assert length(concerns) == 1
        assert length(curiosities) == 1
      end
    end

    test "creates proposals for identity insights", %{state: state, agent_id: agent_id} do
      result = %{
        context: %{
          "session.cognitive_mode" => "",
          "session.new_goals" => [],
          "session.goal_updates" => [],
          "session.memory_notes" => [],
          "session.concerns" => [],
          "session.curiosity" => [],
          "session.identity_insights" => ["I am thorough", "I value correctness"],
          "session.decompositions" => []
        }
      }

      Builders.apply_heartbeat_result(state, result)

      if Code.ensure_loaded?(Arbor.Memory.Proposal) do
        {:ok, proposals} = Arbor.Memory.Proposal.list_pending(agent_id)
        identity_proposals = Enum.filter(proposals, &(&1.type == :identity))
        assert length(identity_proposals) == 2
      end
    end

    test "creates proposals for decompositions", %{state: state, agent_id: agent_id} do
      result = %{
        context: %{
          "session.cognitive_mode" => "",
          "session.new_goals" => [],
          "session.goal_updates" => [],
          "session.memory_notes" => [],
          "session.concerns" => [],
          "session.curiosity" => [],
          "session.identity_insights" => [],
          "session.decompositions" => [
            %{"description" => "Search files", "capability" => "read", "op" => "file"},
            %{"description" => "Analyze results", "capability" => "think", "op" => "reflect"}
          ]
        }
      }

      Builders.apply_heartbeat_result(state, result)

      if Code.ensure_loaded?(Arbor.Memory.Proposal) do
        {:ok, proposals} = Arbor.Memory.Proposal.list_pending(agent_id)
        intent_proposals = Enum.filter(proposals, &(&1.type == :intent))
        assert length(intent_proposals) == 2
      end
    end

    test "no proposals created when heartbeat returns empty results", %{
      state: state,
      agent_id: agent_id
    } do
      result = %{
        context: %{
          "session.cognitive_mode" => "",
          "session.new_goals" => [],
          "session.goal_updates" => [],
          "session.memory_notes" => [],
          "session.concerns" => [],
          "session.curiosity" => [],
          "session.identity_insights" => [],
          "session.decompositions" => []
        }
      }

      Builders.apply_heartbeat_result(state, result)

      if Code.ensure_loaded?(Arbor.Memory.Proposal) do
        {:ok, proposals} = Arbor.Memory.Proposal.list_pending(agent_id)
        assert proposals == []
      end
    end

    test "does not create mode proposal when mode unchanged", %{state: state, agent_id: agent_id} do
      result = %{
        context: %{
          "session.cognitive_mode" => "reflection",
          "session.new_goals" => [],
          "session.goal_updates" => [],
          "session.memory_notes" => [],
          "session.concerns" => [],
          "session.curiosity" => [],
          "session.identity_insights" => [],
          "session.decompositions" => []
        }
      }

      Builders.apply_heartbeat_result(state, result)

      if Code.ensure_loaded?(Arbor.Memory.Proposal) do
        {:ok, proposals} = Arbor.Memory.Proposal.list_pending(agent_id)
        mode_proposals = Enum.filter(proposals, &(&1.type == :cognitive_mode))
        assert mode_proposals == []
      end
    end
  end
end
