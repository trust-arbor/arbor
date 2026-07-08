defmodule Arbor.Actions.ApprovalContextTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  defmodule GatedPolicy do
    def confirmation_mode(_principal, _uri, _opts), do: :gated
    def confirmation_mode(_principal, _uri), do: :gated
  end

  defmodule CapturingConsensus do
    def submit(proposal, _opts \\ []) do
      send(self(), {:proposal, proposal})
      {:ok, "proposal_approval_context"}
    end

    def healthy?, do: true
  end

  setup do
    original_trust_guard = Application.get_env(:arbor_trust, :approval_guard_enabled)
    original_security_guard = Application.get_env(:arbor_security, :approval_guard_enabled)
    original_policy = Application.get_env(:arbor_trust, :policy_module)
    original_escalation = Application.get_env(:arbor_security, :consensus_escalation_enabled)
    original_consensus = Application.get_env(:arbor_security, :consensus_module)
    original_router = Application.get_env(:arbor_security, :use_interaction_router_for_approval)

    Application.put_env(:arbor_trust, :approval_guard_enabled, true)
    Application.put_env(:arbor_security, :approval_guard_enabled, true)
    Application.put_env(:arbor_trust, :policy_module, GatedPolicy)
    Application.put_env(:arbor_security, :consensus_escalation_enabled, true)
    Application.put_env(:arbor_security, :consensus_module, CapturingConsensus)
    Application.put_env(:arbor_security, :use_interaction_router_for_approval, false)

    on_exit(fn ->
      restore(:arbor_trust, :approval_guard_enabled, original_trust_guard)
      restore(:arbor_security, :approval_guard_enabled, original_security_guard)
      restore(:arbor_trust, :policy_module, original_policy)
      restore(:arbor_security, :consensus_escalation_enabled, original_escalation)
      restore(:arbor_security, :consensus_module, original_consensus)
      restore(:arbor_security, :use_interaction_router_for_approval, original_router)
    end)

    tmp_root = Path.expand(System.tmp_dir!())
    tmp_dir = Path.join(tmp_root, "arbor_approval_context_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok,
     tmp_dir: tmp_dir, agent_id: "agent_approval_context_#{System.unique_integer([:positive])}"}
  end

  test "authorize_and_execute produces rich approval context for gated file writes", %{
    agent_id: agent_id,
    tmp_dir: tmp_dir
  } do
    file_path = Path.join(tmp_dir, "vip-report.md")
    content = "VIP export\ncustomer,value\nA,100\n"

    {:ok, _capability} =
      Arbor.Security.grant(
        principal: agent_id,
        resource: "arbor://fs/write#{tmp_dir}/**"
      )

    assert {:ok, :pending_approval, "proposal_approval_context"} =
             Arbor.Actions.authorize_and_execute(
               agent_id,
               Arbor.Actions.File.Write,
               %{path: file_path, content: content},
               %{
                 workspace: tmp_dir,
                 taint: :untrusted,
                 session_id: "session_approval_context",
                 turn_id: "turn_approval_context"
               }
             )

    refute File.exists?(file_path)
    assert_receive {:proposal, proposal}

    assert proposal.context.action == "file.write"
    assert proposal.context.requested_resource_uri == "arbor://fs/write"
    assert proposal.context.resource_uri == "arbor://fs/write#{file_path}"
    assert proposal.context.target == file_path
    assert proposal.context.target_type == :file_path
    assert proposal.context.payload_preview.preview == content
    assert proposal.context.params.content == content
    assert proposal.context.provenance.session_id == "session_approval_context"
    assert proposal.context.provenance.turn_id == "turn_approval_context"
    assert proposal.context.gate == :trust_policy
    assert proposal.context.reason == :policy_gated
    assert proposal.context.risk_hints.operation_taint == :untrusted
    assert proposal.context.risk_hints.in_workspace == true
    assert proposal.metadata.approval_context == proposal.context
    assert proposal.metadata.target == file_path
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
