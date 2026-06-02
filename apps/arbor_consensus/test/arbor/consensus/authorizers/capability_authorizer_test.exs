defmodule Arbor.Consensus.Authorizers.CapabilityAuthorizerTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Consensus.Authorizers.CapabilityAuthorizer
  alias Arbor.Contracts.Consensus.{CouncilDecision, Proposal}

  defp build_proposal(attrs) do
    defaults = %{
      proposer: "agent_oq5_default",
      topic: :code_modification,
      description: "test proposal",
      context: %{}
    }

    {:ok, p} = Proposal.new(Map.merge(defaults, Map.new(attrs)))
    p
  end

  describe "authorize_proposal/1 (OQ-5)" do
    test "denies proposers without arbor://consensus/propose capability" do
      proposal =
        build_proposal(
          id: "prop_oq5_1",
          proposer: "agent_oq5_unprivileged_#{System.unique_integer([:positive])}",
          topic: :code_modification,
          description: "denied proposal"
        )

      assert {:error, {:unauthorized, _reason}} =
               CapabilityAuthorizer.authorize_proposal(proposal)
    end

    test "defaults topic-derived URI when proposal carries an atom topic" do
      proposal =
        build_proposal(
          id: "prop_oq5_3",
          proposer: "agent_oq5_no_topic_#{System.unique_integer([:positive])}",
          topic: :general,
          description: "no topic"
        )

      # Doesn't assert :ok (no caps granted), but the call must reach the
      # security layer with a well-formed URI — i.e. it returns an
      # :unauthorized error, NOT an :invalid_principal error.
      assert {:error, {:unauthorized, reason}} =
               CapabilityAuthorizer.authorize_proposal(proposal)

      refute reason == :invalid_principal
    end
  end

  describe "authorize_execution/2 (OQ-5)" do
    test "denies execution without arbor://consensus/execute capability" do
      proposal =
        build_proposal(
          id: "prop_oq5_4",
          proposer: "agent_oq5_exec_#{System.unique_integer([:positive])}",
          topic: :general,
          description: "denied execution"
        )

      decision = %CouncilDecision{
        id: "dec_oq5_4",
        proposal_id: proposal.id,
        decision: :approved,
        required_quorum: 1,
        quorum_met: true,
        created_at: DateTime.utc_now(),
        decided_at: DateTime.utc_now()
      }

      assert {:error, {:unauthorized, _reason}} =
               CapabilityAuthorizer.authorize_execution(proposal, decision)
    end
  end
end
