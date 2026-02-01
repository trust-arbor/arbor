defmodule Arbor.Security.EscalationTest do
  use ExUnit.Case, async: false

  alias Arbor.Security.Escalation

  # Mock consensus module for testing
  defmodule MockConsensus do
    def submit(%{} = proposal) when is_map_key(proposal, :proposer) do
      {:ok, "proposal_#{:erlang.unique_integer([:positive])}"}
    end

    def healthy?, do: true
  end

  defmodule FailingConsensus do
    def submit(_), do: {:error, :test_failure}
    def healthy?, do: true
  end

  defmodule UnhealthyConsensus do
    def healthy?, do: false
  end

  setup do
    # Save original config
    original_enabled = Application.get_env(:arbor_security, :consensus_escalation_enabled)
    original_module = Application.get_env(:arbor_security, :consensus_module)

    on_exit(fn ->
      if original_enabled do
        Application.put_env(:arbor_security, :consensus_escalation_enabled, original_enabled)
      else
        Application.delete_env(:arbor_security, :consensus_escalation_enabled)
      end

      if original_module do
        Application.put_env(:arbor_security, :consensus_module, original_module)
      else
        Application.delete_env(:arbor_security, :consensus_module)
      end
    end)

    capability = %{
      id: "cap_test",
      principal_id: "agent_test",
      resource_uri: "arbor://fs/write/sensitive",
      constraints: %{requires_approval: true}
    }

    {:ok, capability: capability}
  end

  describe "maybe_escalate/3" do
    test "returns :ok when requires_approval is not set", %{capability: cap} do
      cap = %{cap | constraints: %{}}
      assert :ok = Escalation.maybe_escalate(cap, "agent_test", "arbor://fs/read/docs")
    end

    test "returns :ok when requires_approval is false", %{capability: cap} do
      cap = %{cap | constraints: %{requires_approval: false}}
      assert :ok = Escalation.maybe_escalate(cap, "agent_test", "arbor://fs/read/docs")
    end

    test "returns :ok when escalation is disabled", %{capability: cap} do
      Application.put_env(:arbor_security, :consensus_escalation_enabled, false)
      assert :ok = Escalation.maybe_escalate(cap, "agent_test", "arbor://fs/write/sensitive")
    end

    test "returns :ok when consensus_module is nil", %{capability: cap} do
      Application.put_env(:arbor_security, :consensus_module, nil)
      assert :ok = Escalation.maybe_escalate(cap, "agent_test", "arbor://fs/write/sensitive")
    end

    test "returns pending_approval with proposal_id on successful submission", %{capability: cap} do
      Application.put_env(:arbor_security, :consensus_escalation_enabled, true)
      Application.put_env(:arbor_security, :consensus_module, MockConsensus)

      assert {:ok, :pending_approval, proposal_id} =
               Escalation.maybe_escalate(cap, "agent_test", "arbor://fs/write/sensitive")

      assert String.starts_with?(proposal_id, "proposal_")
    end

    test "returns error when consensus submission fails", %{capability: cap} do
      Application.put_env(:arbor_security, :consensus_escalation_enabled, true)
      Application.put_env(:arbor_security, :consensus_module, FailingConsensus)

      assert {:error, {:consensus_submission_failed, :test_failure}} =
               Escalation.maybe_escalate(cap, "agent_test", "arbor://fs/write/sensitive")
    end

    test "returns error when consensus is unavailable", %{capability: cap} do
      Application.put_env(:arbor_security, :consensus_escalation_enabled, true)
      Application.put_env(:arbor_security, :consensus_module, UnhealthyConsensus)

      assert {:error, :consensus_unavailable} =
               Escalation.maybe_escalate(cap, "agent_test", "arbor://fs/write/sensitive")
    end
  end

  describe "submit_for_approval/4" do
    test "creates proposal with correct structure", %{capability: cap} do
      # Use a module that captures the proposal
      defmodule CapturingConsensus do
        def submit(proposal) do
          send(self(), {:proposal, proposal})
          {:ok, "proposal_123"}
        end

        def healthy?, do: true
      end

      {:ok, :pending_approval, _} =
        Escalation.submit_for_approval(
          CapturingConsensus,
          cap,
          "agent_test",
          "arbor://fs/write/sensitive"
        )

      assert_receive {:proposal, proposal}
      assert proposal.proposer == "agent_test"
      assert proposal.change_type == :authorization_request
      assert proposal.metadata.principal_id == "agent_test"
      assert proposal.metadata.resource_uri == "arbor://fs/write/sensitive"
      assert proposal.metadata.capability_id == "cap_test"
    end
  end
end
