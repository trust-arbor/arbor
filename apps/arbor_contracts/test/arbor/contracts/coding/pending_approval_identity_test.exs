defmodule Arbor.Contracts.Coding.PendingApprovalIdentityTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.PendingApprovalIdentity
  alias Arbor.Contracts.Coding.PendingApprovalResourceId
  alias Arbor.Contracts.Coding.ReconciliationDecision

  @moduletag :fast

  test "normalize binds resource_id to source and approval_id" do
    {:ok, resource_id} = PendingApprovalResourceId.resource_id("consensus", "prop_abc")

    assert {:ok, identity} =
             PendingApprovalIdentity.normalize(%{
               "resource_type" => "pending_approval",
               "resource_id" => resource_id,
               "approval_id" => "prop_abc",
               "source" => "consensus",
               "task_id" => "task_1",
               "agent_id" => "agent_1",
               "principal_id" => "agent_1",
               "approver_id" => nil,
               "resource_uri" => "arbor://shell/exec/git",
               "action" => "execute",
               "status" => "pending",
               "created_at" => "2026-07-28T00:00:00Z"
             })

    assert identity["resource_id"] == resource_id
    assert identity["source"] == "consensus"
    assert identity["status"] == "pending"
  end

  test "normalize rejects resource_id/source mismatch" do
    {:ok, wrong} = PendingApprovalResourceId.resource_id("interaction", "prop_abc")

    assert {:error, _} =
             PendingApprovalIdentity.normalize(%{
               "resource_type" => "pending_approval",
               "resource_id" => wrong,
               "approval_id" => "prop_abc",
               "source" => "consensus",
               "task_id" => nil,
               "agent_id" => "agent_1",
               "principal_id" => "agent_1",
               "approver_id" => nil,
               "resource_uri" => nil,
               "action" => nil,
               "status" => "pending",
               "created_at" => nil
             })
  end

  test "security regression: normalize rejects task ids the agent inventory cannot represent" do
    {:ok, resource_id} = PendingApprovalResourceId.resource_id("consensus", "prop_bad_task")

    assert {:error, {:invalid_field, "task_id"}} =
             PendingApprovalIdentity.normalize(%{
               "resource_type" => "pending_approval",
               "resource_id" => resource_id,
               "approval_id" => "prop_bad_task",
               "source" => "consensus",
               "task_id" => "task id with spaces",
               "agent_id" => "agent_1",
               "principal_id" => "agent_1",
               "approver_id" => nil,
               "resource_uri" => nil,
               "action" => "execute",
               "status" => "pending",
               "created_at" => nil
             })
  end

  test "normalize_settle_fields rejects duplicate canonical outer keys" do
    {:ok, resource_id} = PendingApprovalResourceId.resource_id("consensus", "prop_duplicate")

    expected_identity = %{
      "resource_type" => "pending_approval",
      "resource_id" => resource_id,
      "approval_id" => "prop_duplicate",
      "source" => "consensus",
      "task_id" => "task_1",
      "agent_id" => "agent_1",
      "principal_id" => "agent_1",
      "approver_id" => nil,
      "resource_uri" => "arbor://shell/exec",
      "action" => "execute",
      "status" => "pending",
      "created_at" => nil
    }

    duplicate_keys = %{
      "resource_id" => resource_id,
      :resource_id => resource_id,
      "expected_identity" => expected_identity
    }

    assert {:error, :invalid_reconciliation_settle_fields} =
             PendingApprovalIdentity.normalize_settle_fields(duplicate_keys)
  end

  test "from_consensus_proposal projects closed identity" do
    created = ~U[2026-07-28 12:00:00Z]

    proposal = %{
      id: "prop_auth_1",
      proposer: "agent_x",
      topic: :authorization_request,
      status: :pending,
      metadata: %{
        principal_id: "agent_x",
        resource_uri: "arbor://fs/read/tmp",
        action: "read",
        task_id: "task_z"
      },
      context: %{},
      created_at: created
    }

    assert {:ok, identity} = PendingApprovalIdentity.from_consensus_proposal(proposal)
    assert identity["approval_id"] == "prop_auth_1"
    assert identity["source"] == "consensus"
    assert identity["task_id"] == "task_z"
    assert identity["status"] == "pending"
    assert identity["created_at"] == DateTime.to_iso8601(created)
  end

  test "ReconciliationDecision delegates pending identity to the shared normalizer" do
    {:ok, resource_id} = PendingApprovalResourceId.resource_id("interaction", "irq_one")

    assert {:ok, decision} =
             ReconciliationDecision.new(%{
               schema_version: 1,
               resource_type: "pending_approval",
               resource_id: resource_id,
               task_id: "task_1",
               principal_id: "agent_1",
               decision: "settle",
               reason: "terminal_active_resource",
               expected_identity: %{
                 resource_type: "pending_approval",
                 resource_id: resource_id,
                 approval_id: "irq_one",
                 source: "interaction",
                 task_id: "task_1",
                 agent_id: "agent_1",
                 principal_id: "agent_1",
                 approver_id: "user_1",
                 resource_uri: "arbor://shell/exec/ls",
                 action: "execute",
                 status: "pending",
                 created_at: "2026-07-28T01:00:00Z"
               },
               evidence: %{
                 task_presence: "observed",
                 task_state: "waiting_approval",
                 owner_status: "dead",
                 journal_status: "complete"
               }
             })

    assert decision.expected_identity["source"] == "interaction"
    assert decision.expected_identity["resource_id"] == resource_id
  end
end
