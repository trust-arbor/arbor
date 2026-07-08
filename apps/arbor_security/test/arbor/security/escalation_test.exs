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

  defmodule CapturingConsensus do
    def submit(proposal, _opts \\ []) do
      send(self(), {:proposal, proposal})
      {:ok, "proposal_123"}
    end

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

    test "stores approval context in interaction metadata", %{capability: cap} do
      Application.put_env(:arbor_security, :consensus_escalation_enabled, true)
      Application.put_env(:arbor_security, :consensus_module, MockConsensus)
      Application.put_env(:arbor_security, :use_interaction_router_for_approval, true)

      on_exit(fn ->
        Application.delete_env(:arbor_security, :use_interaction_router_for_approval)
      end)

      opts = [
        approval_action: "file.write",
        file_path: "/workspace/report.md",
        content: "approval preview body",
        workspace: "/workspace",
        operation_taint: :untrusted,
        gate: :trust_policy,
        reason: :policy_gated,
        session_id: "session_1"
      ]

      assert {:ok, :pending_approval, request_id} =
               Escalation.maybe_escalate(cap, "agent_test", "arbor://fs/write/sensitive", opts)

      assert {:ok, interaction} = Arbor.Comms.InteractionRegistry.get(request_id)

      assert interaction.metadata.target == "/workspace/report.md"
      assert interaction.metadata.gate == :trust_policy
      assert interaction.metadata.reason == :policy_gated

      context = interaction.metadata.approval_context
      assert context.action == "file.write"
      assert context.target_type == :file_path
      assert context.payload_preview.preview == "approval preview body"
      assert context.provenance.session_id == "session_1"
      assert context.risk_hints.in_workspace == true
      assert interaction.description =~ "/workspace/report.md"
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

    test "creates proposal with decision context", %{capability: cap} do
      opts = [
        approval_action: "file.write",
        file_path: "/workspace/report.md",
        content: "approval preview body",
        params: %{path: "/workspace/report.md", content: "approval preview body", token: "secret"},
        workspace: "/workspace",
        operation_taint: :untrusted,
        gate: :trust_policy,
        reason: :policy_gated,
        session_id: "session_1"
      ]

      {:ok, :pending_approval, _} =
        Escalation.submit_for_approval(
          CapturingConsensus,
          cap,
          "agent_test",
          "arbor://fs/write/sensitive",
          opts
        )

      assert_receive {:proposal, proposal}

      assert proposal.context.action == "file.write"
      assert proposal.context.target == "/workspace/report.md"
      assert proposal.context.target_type == :file_path
      assert proposal.context.payload_preview.kind == "content"
      assert proposal.context.payload_preview.preview == "approval preview body"
      assert proposal.context.params.token == "[REDACTED]"
      assert proposal.context.provenance.session_id == "session_1"
      assert proposal.context.gate == :trust_policy
      assert proposal.context.reason == :policy_gated
      assert proposal.context.risk_hints.operation_taint == :untrusted
      assert proposal.context.risk_hints.in_workspace == true

      assert proposal.metadata.approval_context == proposal.context
      assert proposal.metadata.target == "/workspace/report.md"
      assert proposal.description =~ "/workspace/report.md"
    end

    test "security regression: supplied approval context cannot bypass preview redaction", %{
      capability: cap
    } do
      jwt =
        "eyJhbGciOiJIUzI1NiJ9" <>
          "." <>
          "eyJzdWIiOiIxMjM0NTY3ODkwIn0" <>
          "." <> "dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"

      body =
        ~s({"message":"keep","access_token":"tiny","authorization":"Bearer short-token","jwt":"#{jwt}"})

      opts = [
        approval_context: %{
          payload_preview: %{
            kind: "content",
            bytes: byte_size(body),
            truncated: false,
            preview: body
          },
          params: %{
            "credentials" => "smallcred",
            "note" => "token #{jwt}",
            "nested" => %{"access-token" => "nestedtiny"}
          }
        }
      ]

      {:ok, :pending_approval, _} =
        Escalation.submit_for_approval(
          CapturingConsensus,
          cap,
          "agent_test",
          "arbor://fs/write/sensitive",
          opts
        )

      assert_receive {:proposal, proposal}

      preview = proposal.context.payload_preview.preview
      assert preview =~ ~s("message":"keep")
      refute preview =~ "tiny"
      refute preview =~ "short-token"
      refute preview =~ jwt

      assert proposal.context.params["credentials"] == "[REDACTED]"
      assert proposal.context.params["nested"]["access-token"] == "[REDACTED]"
      refute proposal.context.params["note"] =~ jwt
      assert proposal.metadata.approval_context == proposal.context
    end
  end
end
