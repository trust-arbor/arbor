defmodule Arbor.Contracts.Consensus.ConsensusEventTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Consensus.ConsensusEvent

  @valid_attrs %{
    event_type: :proposal_submitted,
    proposal_id: "prop_123",
    agent_id: "agent_1"
  }

  describe "new/1" do
    test "creates event with valid attributes" do
      assert {:ok, %ConsensusEvent{} = e} = ConsensusEvent.new(@valid_attrs)
      assert e.event_type == :proposal_submitted
      assert e.proposal_id == "prop_123"
      assert e.agent_id == "agent_1"
      assert String.starts_with?(e.id, "cev_")
      assert %DateTime{} = e.timestamp
    end

    test "accepts all optional fields" do
      {:ok, e} =
        ConsensusEvent.new(
          Map.merge(@valid_attrs, %{
            evaluator_id: "eval_1",
            decision_id: "dec_1",
            data: %{key: "val"},
            vote: :approve,
            perspective: :security,
            confidence: 0.9,
            decision: :approved,
            approve_count: 5,
            reject_count: 1,
            abstain_count: 1,
            correlation_id: "corr_1"
          })
        )

      assert e.evaluator_id == "eval_1"
      assert e.vote == :approve
      assert e.confidence == 0.9
    end

    test "errors on invalid event_type" do
      attrs = %{@valid_attrs | event_type: :bogus_type}
      assert {:error, {:invalid_event, _}} = ConsensusEvent.new(attrs)
    end

    test "errors on missing proposal_id" do
      attrs = Map.delete(@valid_attrs, :proposal_id)
      assert {:error, {:invalid_event, _}} = ConsensusEvent.new(attrs)
    end

    test "errors on missing event_type" do
      attrs = Map.delete(@valid_attrs, :event_type)
      assert {:error, {:invalid_event, _}} = ConsensusEvent.new(attrs)
    end
  end

  describe "event_types/0" do
    test "returns all known event types" do
      types = ConsensusEvent.event_types()
      assert :proposal_submitted in types
      assert :evaluation_submitted in types
      assert :decision_reached in types
      assert :execution_succeeded in types
      assert :proposal_cancelled in types
      assert length(types) == 10
    end
  end

  describe "terminal?/1" do
    test "execution_succeeded is terminal" do
      {:ok, e} = ConsensusEvent.new(%{@valid_attrs | event_type: :execution_succeeded})
      assert ConsensusEvent.terminal?(e) == true
    end

    test "execution_failed is terminal" do
      {:ok, e} = ConsensusEvent.new(%{@valid_attrs | event_type: :execution_failed})
      assert ConsensusEvent.terminal?(e) == true
    end

    test "proposal_cancelled is terminal" do
      {:ok, e} = ConsensusEvent.new(%{@valid_attrs | event_type: :proposal_cancelled})
      assert ConsensusEvent.terminal?(e) == true
    end

    test "proposal_submitted is not terminal" do
      {:ok, e} = ConsensusEvent.new(@valid_attrs)
      assert ConsensusEvent.terminal?(e) == false
    end
  end

  describe "convenience constructors" do
    test "proposal_submitted/1" do
      {:ok, e} =
        ConsensusEvent.proposal_submitted(%{
          proposal_id: "prop_1",
          agent_id: "agent_1",
          change_type: :code_modification,
          description: "Add caching"
        })

      assert e.event_type == :proposal_submitted
      assert e.data[:change_type] == :code_modification
    end

    test "evaluation_submitted/1" do
      {:ok, e} =
        ConsensusEvent.evaluation_submitted(%{
          proposal_id: "prop_1",
          evaluator_id: "eval_1",
          vote: :approve,
          perspective: :security,
          confidence: 0.9,
          reasoning: "looks good",
          risk_score: 0.1,
          benefit_score: 0.8
        })

      assert e.event_type == :evaluation_submitted
      assert e.vote == :approve
    end

    test "decision_reached/1" do
      {:ok, e} =
        ConsensusEvent.decision_reached(%{
          proposal_id: "prop_1",
          decision: :approved,
          approve_count: 5,
          reject_count: 1,
          abstain_count: 1,
          quorum_met: true,
          required_quorum: 5
        })

      assert e.event_type == :decision_reached
      assert e.decision == :approved
    end

    test "execution_event/2" do
      for status <- [:started, :succeeded, :failed] do
        {:ok, e} =
          ConsensusEvent.execution_event(status, %{
            proposal_id: "prop_1",
            result: :ok
          })

        assert e.event_type == :"execution_#{status}"
      end
    end
  end

  describe "to_map/1 and from_map/1" do
    test "round-trips through map" do
      {:ok, original} =
        ConsensusEvent.new(
          Map.merge(@valid_attrs, %{
            vote: :approve,
            perspective: :security,
            decision: :approved
          })
        )

      map = ConsensusEvent.to_map(original)
      assert is_binary(map.timestamp)
      assert map.event_type == :proposal_submitted

      {:ok, restored} = ConsensusEvent.from_map(map)
      assert restored.event_type == original.event_type
      assert restored.proposal_id == original.proposal_id
    end
  end
end
