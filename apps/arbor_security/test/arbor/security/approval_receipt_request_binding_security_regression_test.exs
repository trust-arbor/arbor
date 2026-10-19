defmodule Arbor.Security.ApprovalReceiptRequestBindingSecurityRegressionTest do
  @moduledoc """
  Security regression (Arbor Exposure Check group F, 2026-10-19):
  `ApprovalReceiptBroker` signs `request_id` at issue but consume/verify only
  compared principal, resource, action, and the args digest. A receipt minted
  for request A could authorize request B with identical arguments — the
  confused-deputy shape in arXiv:2610.23077 (*When Approval Becomes Execution*).
  """
  use ExUnit.Case, async: false

  alias Arbor.Security
  alias Arbor.Security.ApprovalReceiptBroker

  @moduletag :fast
  @moduletag :security_regression

  setup do
    agent_id = "agent_#{:erlang.unique_integer([:positive])}"
    resource = "arbor://code/read/request_bind_#{:erlang.unique_integer([:positive])}"
    Application.put_env(:arbor_security, :consensus_escalation_enabled, false)

    {:ok, _cap} =
      Security.grant_fixture(
        principal: agent_id,
        resource: resource,
        constraints: %{requires_approval: true}
      )

    arguments = %{"path" => "/approved/exact"}
    {:ok, digest} = Security.approval_argument_digest(arguments)

    {:ok, receipt} =
      ApprovalReceiptBroker.issue_for_test(
        agent_id,
        resource,
        :execute,
        digest,
        "irq_request_a"
      )

    %{agent_id: agent_id, resource: resource, digest: digest, receipt: receipt}
  end

  test "security regression: a receipt issued for request A is rejected for request B with identical args",
       %{agent_id: agent_id, resource: resource, digest: digest, receipt: receipt} do
    assert {:error, :invalid_approval_receipt} =
             Security.authorize(agent_id, resource, :execute,
               approved_invocation: receipt,
               argument_digest: digest,
               request_id: "irq_request_b"
             )

    assert {:error, :invalid_approval_receipt} =
             ApprovalReceiptBroker.consume(
               receipt,
               agent_id,
               resource,
               :execute,
               digest,
               "irq_request_b"
             )

    assert {:ok, :authorized} =
             Security.authorize(agent_id, resource, :execute,
               approved_invocation: receipt,
               argument_digest: digest,
               request_id: "irq_request_a"
             )
  end
end
