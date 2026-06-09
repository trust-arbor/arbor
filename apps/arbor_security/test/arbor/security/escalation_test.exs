defmodule Arbor.Security.EscalationTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Security.Escalation

  # One-time bootstrap for the InteractionRouter dependencies. Idempotent.
  # Called from the describe-block setup that needs the router.
  def __bootstrap_router__ do
    pubsub = Arbor.Comms.PubSub

    # Start Phoenix.PubSub only if it isn't already running. The arbor_comms
    # application (or a peer test) may already own a PubSub of this name;
    # unconditionally starting a second owner makes the child fail with
    # {:already_started, _}, which — under a LINKED Supervisor.start_link —
    # shuts the supervisor down and crashes this (linked) test process with
    # "failed to start child". Guard on whereis so we reuse the existing one.
    if Process.whereis(pubsub) == nil do
      case Supervisor.start_link(
             [{Phoenix.PubSub, name: pubsub}],
             strategy: :one_for_one,
             name: :Escalation_RouterTest_Sup
           ) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        # Lost a race — someone else started it between whereis and now.
        {:error, {:shutdown, {:failed_to_start_child, _, {:already_started, _}}}} -> :ok
      end
    end

    case Arbor.Comms.InteractionRegistry.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case Arbor.Comms.PresenceTracker.start_link(pubsub_server: pubsub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  # Mock consensus module for testing
  defmodule MockConsensus do
    def submit(%{} = proposal, _opts \\ []) when is_map_key(proposal, :proposer) do
      {:ok, "proposal_#{:erlang.unique_integer([:positive])}"}
    end

    def healthy?, do: true
  end

  defmodule FailingConsensus do
    def submit(_, _opts \\ []), do: {:error, :test_failure}
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

    test "returns error when escalation is disabled but approval required", %{capability: cap} do
      Application.put_env(:arbor_security, :consensus_escalation_enabled, false)

      assert {:error, :escalation_disabled} =
               Escalation.maybe_escalate(cap, "agent_test", "arbor://fs/write/sensitive")
    end

    test "returns error when consensus_module is nil but approval required", %{capability: cap} do
      Application.put_env(:arbor_security, :consensus_module, nil)

      assert {:error, :no_consensus_module} =
               Escalation.maybe_escalate(cap, "agent_test", "arbor://fs/write/sensitive")
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

  describe "InteractionRouter path (Phase 1, feature-flagged)" do
    setup do
      __MODULE__.__bootstrap_router__()
      Arbor.Comms.InteractionRegistry.reset()
      :ok
    end

    test "with the feature flag on, uses InteractionRouter instead of consensus",
         %{capability: cap} do
      Application.put_env(:arbor_security, :consensus_escalation_enabled, true)
      Application.put_env(:arbor_security, :consensus_module, MockConsensus)
      Application.put_env(:arbor_security, :use_interaction_router_for_approval, true)

      on_exit(fn ->
        Application.delete_env(:arbor_security, :use_interaction_router_for_approval)
      end)

      assert {:ok, :pending_approval, request_id} =
               Escalation.maybe_escalate(cap, "agent_test", "arbor://fs/write/sensitive")

      assert String.starts_with?(request_id, "irq_")

      # Verify the interaction landed in the registry rather than
      # going through the consensus mock.
      assert {:ok, interaction} = Arbor.Comms.InteractionRegistry.get(request_id)
      assert interaction.agent_id == "agent_test"
      assert interaction.resource_uri == "arbor://fs/write/sensitive"
      assert interaction.kind == :approval
      assert interaction.metadata.capability_id == cap.id
    end

    test "with the feature flag off, the consensus path runs (backward compat)",
         %{capability: cap} do
      Application.put_env(:arbor_security, :consensus_escalation_enabled, true)
      Application.put_env(:arbor_security, :consensus_module, MockConsensus)
      Application.put_env(:arbor_security, :use_interaction_router_for_approval, false)

      assert {:ok, :pending_approval, proposal_id} =
               Escalation.maybe_escalate(cap, "agent_test", "arbor://fs/write/sensitive")

      assert String.starts_with?(proposal_id, "proposal_")
    end
  end

  describe "submit_for_approval/4" do
    test "creates proposal with correct structure", %{capability: cap} do
      # Use a module that captures the proposal
      defmodule CapturingConsensus do
        def submit(proposal, _opts \\ []) do
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
      assert proposal.topic == :authorization_request
      assert proposal.metadata.principal_id == "agent_test"
      assert proposal.metadata.resource_uri == "arbor://fs/write/sensitive"
      assert proposal.metadata.capability_id == "cap_test"
    end
  end
end
