defmodule Arbor.Consensus.AuthorizationTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :integration

  @caller_id "agent_test_caller"

  setup do
    # When Security is fully running (cross-app umbrella tests), we need
    # to grant capabilities. When it's not running, authorize/2 permits by default.
    grant_consensus_capabilities(@caller_id)
    :ok
  end

  describe "authorize_propose/3" do
    test "delegates to propose when security permits" do
      attrs = %{
        proposer: @caller_id,
        topic: :code_modification,
        description: "Test proposal via authorize_propose",
        context: %{}
      }

      assert {:ok, proposal_id} = Arbor.Consensus.authorize_propose(@caller_id, attrs)
      assert is_binary(proposal_id)
    end
  end

  describe "authorize_ask/3" do
    test "delegates to ask when security permits" do
      assert {:ok, proposal_id} =
               Arbor.Consensus.authorize_ask(@caller_id, "Test advisory question")

      assert is_binary(proposal_id)
    end
  end

  describe "authorize_cancel/3" do
    test "delegates to cancel when security permits" do
      {:ok, proposal_id} =
        Arbor.Consensus.propose(%{
          proposer: @caller_id,
          topic: :code_modification,
          description: "Proposal to cancel"
        })

      # The cancel may succeed or fail depending on proposal state,
      # but it should not return {:error, {:unauthorized, _}}
      result = Arbor.Consensus.authorize_cancel(@caller_id, proposal_id)
      refute match?({:error, {:unauthorized, _}}, result)
    end
  end

  describe "authorize_force_approve/4" do
    test "delegates to force_approve when security permits" do
      {:ok, proposal_id} =
        Arbor.Consensus.propose(%{
          proposer: "agent_1",
          topic: :code_modification,
          description: "Proposal to force approve"
        })

      # Wait briefly for evaluation to complete
      Process.sleep(50)

      result = Arbor.Consensus.authorize_force_approve(@caller_id, proposal_id, "admin")
      # Should not be unauthorized (Security is available in consensus tests)
      # May fail for other reasons (already decided, etc.)
      refute match?({:error, {:unauthorized, _}}, result)
    end
  end

  describe "authorize_force_reject/4" do
    test "delegates to force_reject when security permits" do
      {:ok, proposal_id} =
        Arbor.Consensus.propose(%{
          proposer: "agent_1",
          topic: :code_modification,
          description: "Proposal to force reject"
        })

      Process.sleep(50)

      result = Arbor.Consensus.authorize_force_reject(@caller_id, proposal_id, "admin")
      refute match?({:error, {:unauthorized, _}}, result)
    end
  end

  describe "authorize_decide/3" do
    @tag :llm
    test "delegates to decide when security permits" do
      # decide requires LLM — tag as :llm
      result = Arbor.Consensus.authorize_decide(@caller_id, "Should we test?")
      refute match?({:error, {:unauthorized, _}}, result)
    end
  end

  describe "function signatures" do
    test "all authorize_* functions are exported" do
      exports = Arbor.Consensus.__info__(:functions)

      assert {:authorize_propose, 2} in exports or {:authorize_propose, 3} in exports
      assert {:authorize_ask, 2} in exports or {:authorize_ask, 3} in exports
      assert {:authorize_decide, 2} in exports or {:authorize_decide, 3} in exports
      assert {:authorize_cancel, 2} in exports or {:authorize_cancel, 3} in exports
      assert {:authorize_force_approve, 3} in exports or {:authorize_force_approve, 4} in exports
      assert {:authorize_force_reject, 3} in exports or {:authorize_force_reject, 4} in exports
    end
  end

  # Grant wildcard consensus capabilities when Security is running.
  # When Security is not loaded, authorize/2 permits by default.
  defp grant_consensus_capabilities(caller_id) do
    if Code.ensure_loaded?(Arbor.Security.CapabilityStore) and
         Process.whereis(Arbor.Security.CapabilityStore) != nil do
      consensus_uris = [
        "arbor://consensus/propose",
        "arbor://consensus/ask",
        "arbor://consensus/cancel",
        "arbor://consensus/force_approve",
        "arbor://consensus/force_reject",
        "arbor://consensus/decide"
      ]

      for uri <- consensus_uris do
        {:ok, cap} =
          Arbor.Contracts.Security.Capability.new(
            resource_uri: uri,
            principal_id: caller_id,
            actions: [:all]
          )

        Arbor.Security.CapabilityStore.put(cap)
      end
    end
  end
end
