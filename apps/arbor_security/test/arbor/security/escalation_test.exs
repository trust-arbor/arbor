defmodule Arbor.Security.EscalationTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Security.Config
  alias Arbor.Security.Escalation

  defmodule FakeInteractionRouter do
    @moduledoc false
    use Agent
    @behaviour Arbor.Security.Contracts.InteractionRouter

    def child_spec(_opts) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [[]]}
      }
    end

    def start_link(opts \\ []) do
      Agent.start_link(fn -> %{} end, Keyword.merge([name: __MODULE__], opts))
    end

    @impl true
    def request(attrs, _opts \\ []) do
      request_id =
        Map.get(attrs, :request_id) ||
          "irq_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

      interaction = %{
        request_id: request_id,
        kind: Map.get(attrs, :kind, :approval),
        agent_id: Map.get(attrs, :agent_id),
        user_id: Map.get(attrs, :user_id),
        description: Map.get(attrs, :description, ""),
        resource_uri: Map.get(attrs, :resource_uri),
        metadata: Map.get(attrs, :metadata, %{})
      }

      Agent.update(__MODULE__, &Map.put(&1, request_id, interaction))
      {:ok, request_id}
    end

    def get(request_id) do
      case Agent.get(__MODULE__, &Map.get(&1, request_id)) do
        nil -> {:error, :not_found}
        interaction -> {:ok, interaction}
      end
    end
  end

  defmodule NotARouter do
    @moduledoc false
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
    previous = %{
      consensus_escalation_enabled:
        Application.get_env(:arbor_security, :consensus_escalation_enabled, :unset),
      consensus_module: Application.get_env(:arbor_security, :consensus_module, :unset),
      use_interaction_router_for_approval:
        Application.get_env(:arbor_security, :use_interaction_router_for_approval, :unset),
      interaction_router: Application.get_env(:arbor_security, :interaction_router, :unset)
    }

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> restore_env(key, value) end)
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

    test "with the feature flag on, falls back to consensus when the router is unavailable",
         %{capability: cap} do
      Application.put_env(:arbor_security, :consensus_escalation_enabled, true)
      Application.put_env(:arbor_security, :consensus_module, MockConsensus)
      Application.put_env(:arbor_security, :use_interaction_router_for_approval, true)
      Application.put_env(:arbor_security, :interaction_router, NotARouter)

      assert {:ok, :pending_approval, proposal_id} =
               Escalation.maybe_escalate(cap, "agent_test", "arbor://fs/write/sensitive")

      assert String.starts_with?(proposal_id, "proposal_")
    end
  end

  describe "config seam" do
    test "interaction_router defaults to Arbor.Comms.InteractionRouter" do
      Application.delete_env(:arbor_security, :interaction_router)

      assert Config.interaction_router() ==
               Module.concat(["Arbor", "Comms", "InteractionRouter"])
    end
  end

  describe "InteractionRouter path (Phase 1, feature-flagged)" do
    setup do
      start_supervised!(FakeInteractionRouter)
      Application.put_env(:arbor_security, :interaction_router, FakeInteractionRouter)
      :ok
    end

    test "with the feature flag on, uses InteractionRouter instead of consensus",
         %{capability: cap} do
      Application.put_env(:arbor_security, :consensus_escalation_enabled, true)
      Application.put_env(:arbor_security, :consensus_module, MockConsensus)
      Application.put_env(:arbor_security, :use_interaction_router_for_approval, true)

      assert {:ok, :pending_approval, request_id} =
               Escalation.maybe_escalate(cap, "agent_test", "arbor://fs/write/sensitive")

      assert String.starts_with?(request_id, "irq_")

      # Verify the interaction landed in the local router rather than
      # going through the consensus mock.
      assert {:ok, interaction} = FakeInteractionRouter.get(request_id)
      assert interaction.agent_id == "agent_test"
      assert interaction.resource_uri == "arbor://fs/write/sensitive"
      assert interaction.kind == :approval
      assert interaction.metadata.capability_id == cap.id
    end

    test "stores approval context in interaction metadata", %{capability: cap} do
      Application.put_env(:arbor_security, :consensus_escalation_enabled, true)
      Application.put_env(:arbor_security, :consensus_module, MockConsensus)
      Application.put_env(:arbor_security, :use_interaction_router_for_approval, true)

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

      assert {:ok, interaction} = FakeInteractionRouter.get(request_id)

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

  defp restore_env(key, :unset), do: Application.delete_env(:arbor_security, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_security, key, value)
end
