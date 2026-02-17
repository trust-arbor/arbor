defmodule Arbor.Contracts.Consensus.EventsTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Consensus.Events

  describe "event struct creation" do
    test "CoordinatorStarted" do
      event =
        Events.CoordinatorStarted.new(%{
          coordinator_id: "coord_1",
          config: %{timeout: 5000}
        })

      assert event.coordinator_id == "coord_1"
      assert event.config == %{timeout: 5000}
      assert %DateTime{} = event.timestamp
      assert Events.CoordinatorStarted.event_type() == "coordinator.started"
    end

    test "ProposalSubmitted" do
      event =
        Events.ProposalSubmitted.new(%{
          proposal_id: "prop_1",
          proposer: "agent_1",
          change_type: :code_modification,
          description: "Add cache"
        })

      assert event.proposal_id == "prop_1"
      assert event.proposer == "agent_1"
      assert event.change_type == :code_modification
      assert Events.ProposalSubmitted.event_type() == "proposal.submitted"
    end

    test "ProposalSubmitted with module stringification" do
      event =
        Events.ProposalSubmitted.new(%{
          proposal_id: "prop_1",
          proposer: "agent_1",
          change_type: :code_modification,
          description: "Fix",
          target_module: MyApp.Worker
        })

      assert is_binary(event.target_module)
    end

    test "EvaluationStarted" do
      event =
        Events.EvaluationStarted.new(%{
          proposal_id: "prop_1",
          perspectives: [:security, :stability],
          council_size: 7,
          required_quorum: 5
        })

      assert event.perspectives == [:security, :stability]
      assert event.council_size == 7
      assert Events.EvaluationStarted.event_type() == "evaluation.started"
    end

    test "EvaluationCompleted" do
      event =
        Events.EvaluationCompleted.new(%{
          proposal_id: "prop_1",
          evaluation_id: "eval_1",
          perspective: :security,
          vote: :approve,
          confidence: 0.9,
          concerns: ["none"]
        })

      assert event.vote == :approve
      assert event.confidence == 0.9
      assert Events.EvaluationCompleted.event_type() == "evaluation.completed"
    end

    test "EvaluationFailed" do
      event =
        Events.EvaluationFailed.new(%{
          proposal_id: "prop_1",
          perspective: :security,
          reason: "Timeout after 30s"
        })

      assert event.reason == "Timeout after 30s"
      assert Events.EvaluationFailed.event_type() == "evaluation.failed"
    end

    test "DecisionRendered" do
      event =
        Events.DecisionRendered.new(%{
          proposal_id: "prop_1",
          decision_id: "dec_1",
          decision: :approved,
          approve_count: 5,
          reject_count: 1,
          abstain_count: 1,
          required_quorum: 5,
          quorum_met: true
        })

      assert event.decision == :approved
      assert event.quorum_met == true
      assert Events.DecisionRendered.event_type() == "decision.rendered"
    end

    test "ProposalExecuted" do
      event =
        Events.ProposalExecuted.new(%{
          proposal_id: "prop_1",
          result: :ok,
          output: "Applied successfully"
        })

      assert event.result == :ok
      assert Events.ProposalExecuted.event_type() == "proposal.executed"
    end

    test "ProposalDeadlocked" do
      event =
        Events.ProposalDeadlocked.new(%{
          proposal_id: "prop_1",
          reason: :no_quorum,
          details: "Only 3/7 votes"
        })

      assert event.reason == :no_quorum
      assert Events.ProposalDeadlocked.event_type() == "proposal.deadlocked"
    end

    test "RecoveryStarted" do
      event =
        Events.RecoveryStarted.new(%{
          coordinator_id: "coord_1",
          from_position: 42
        })

      assert event.from_position == 42
      assert Events.RecoveryStarted.event_type() == "recovery.started"
    end

    test "RecoveryCompleted" do
      event =
        Events.RecoveryCompleted.new(%{
          coordinator_id: "coord_1",
          proposals_recovered: 3,
          decisions_recovered: 2,
          interrupted_count: 1,
          events_replayed: 15
        })

      assert event.proposals_recovered == 3
      assert Events.RecoveryCompleted.event_type() == "recovery.completed"
    end
  end

  describe "all_event_types/0" do
    test "returns all 10 event type strings" do
      types = Events.all_event_types()
      assert length(types) == 10
      assert "coordinator.started" in types
      assert "proposal.submitted" in types
      assert "decision.rendered" in types
      assert "recovery.completed" in types
    end
  end

  describe "type_to_module/1" do
    test "maps known types to modules" do
      assert Events.type_to_module("coordinator.started") == Events.CoordinatorStarted
      assert Events.type_to_module("proposal.submitted") == Events.ProposalSubmitted
      assert Events.type_to_module("decision.rendered") == Events.DecisionRendered
    end

    test "returns nil for unknown type" do
      assert Events.type_to_module("unknown.type") == nil
    end
  end

  describe "to_persistence_event/3" do
    test "serializes event to persistence format" do
      event =
        Events.ProposalSubmitted.new(%{
          proposal_id: "prop_1",
          proposer: "agent_1",
          change_type: :code_modification,
          description: "Add cache"
        })

      pe = Events.to_persistence_event(event, "arbor:consensus")
      assert pe.stream_id == "arbor:consensus"
      assert pe.type == "proposal.submitted"
      assert is_map(pe.data)
      assert pe.data[:change_type] == "code_modification"
    end

    test "round-trips through persistence format" do
      event =
        Events.EvaluationCompleted.new(%{
          proposal_id: "prop_1",
          evaluation_id: "eval_1",
          perspective: :security,
          vote: :approve,
          confidence: 0.9
        })

      pe = Events.to_persistence_event(event, "arbor:consensus")

      {:ok, restored} = Events.from_persistence_event(pe)
      assert restored.proposal_id == "prop_1"
      assert restored.perspective == :security
      assert restored.vote == :approve
    end
  end

  describe "from_persistence_event/1" do
    test "returns error for unknown event type" do
      pe = %{type: "unknown.event", data: %{}, timestamp: DateTime.utc_now()}
      assert {:error, {:unknown_event_type, "unknown.event"}} = Events.from_persistence_event(pe)
    end
  end
end
