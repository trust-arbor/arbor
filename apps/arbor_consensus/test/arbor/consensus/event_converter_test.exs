defmodule Arbor.Consensus.EventConverterTest do
  use ExUnit.Case, async: true

  alias Arbor.Consensus.EventConverter
  alias Arbor.Contracts.Consensus.ConsensusEvent
  alias Arbor.Persistence.Event, as: PersistenceEvent

  defp build_consensus_event(overrides \\ %{}) do
    {:ok, event} =
      ConsensusEvent.new(
        Map.merge(
          %{
            event_type: :proposal_submitted,
            proposal_id: "prop_123",
            agent_id: "agent_456",
            data: %{change_type: :code_modification}
          },
          overrides
        )
      )

    event
  end

  describe "to_persistence_event/1" do
    test "converts a consensus event to a persistence event" do
      consensus_event = build_consensus_event()
      result = EventConverter.to_persistence_event(consensus_event)

      assert %PersistenceEvent{} = result
      assert result.id == consensus_event.id
      assert result.stream_id == "consensus:prop_123"
      assert result.type == "arbor.consensus.proposal_submitted"
      assert result.data.proposal_id == "prop_123"
      assert result.data.agent_id == "agent_456"
      assert result.correlation_id == consensus_event.correlation_id
      assert result.timestamp == consensus_event.timestamp
    end

    test "preserves evaluation data" do
      event =
        build_consensus_event(%{
          event_type: :evaluation_submitted,
          evaluator_id: "eval_1",
          vote: :approve,
          perspective: :security,
          confidence: 0.85
        })

      result = EventConverter.to_persistence_event(event)

      assert result.data.vote == :approve
      assert result.data.perspective == :security
      assert result.data.confidence == 0.85
      assert result.data.evaluator_id == "eval_1"
    end

    test "preserves decision data" do
      event =
        build_consensus_event(%{
          event_type: :decision_reached,
          decision: :approved,
          approve_count: 3,
          reject_count: 1,
          abstain_count: 0
        })

      result = EventConverter.to_persistence_event(event)

      assert result.data.decision == :approved
      assert result.data.approve_count == 3
      assert result.data.reject_count == 1
    end
  end

  describe "from_persistence_event/1" do
    test "converts a persistence event back to a consensus event" do
      consensus_event = build_consensus_event()
      persistence_event = EventConverter.to_persistence_event(consensus_event)

      assert {:ok, restored} = EventConverter.from_persistence_event(persistence_event)
      assert restored.id == consensus_event.id
      assert restored.event_type == :proposal_submitted
      assert restored.proposal_id == "prop_123"
      assert restored.agent_id == "agent_456"
    end

    test "roundtrip preserves evaluation fields" do
      event =
        build_consensus_event(%{
          event_type: :evaluation_submitted,
          evaluator_id: "eval_1",
          vote: :approve,
          perspective: :security,
          confidence: 0.85
        })

      persistence = EventConverter.to_persistence_event(event)
      {:ok, restored} = EventConverter.from_persistence_event(persistence)

      assert restored.event_type == :evaluation_submitted
      assert restored.vote == :approve
      assert restored.perspective == :security
      assert restored.confidence == 0.85
    end
  end

  describe "stream_id/1" do
    test "returns consensus:proposal_id format" do
      event = build_consensus_event(%{proposal_id: "prop_xyz"})
      assert EventConverter.stream_id(event) == "consensus:prop_xyz"
    end
  end
end
