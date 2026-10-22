defmodule Arbor.Security.ApprovalReceiptPolicyBindingSecurityRegressionTest do
  @moduledoc """
  Security regression (Arbor Exposure Check follow-up on PR #25, 2026-10-22):
  `ApprovalReceiptBroker` receipts were not bound to the effective policy.
  A receipt issued under policy X still authorized after the policy tightened
  to Y.
  """
  use ExUnit.Case, async: false

  alias Arbor.Security
  alias Arbor.Security.ApprovalReceiptBroker

  @moduletag :fast
  @moduletag :security_regression

  setup do
    previous = Application.get_env(:arbor_security, :approval_policy_digest)

    on_exit(fn ->
      restore_policy_digest(previous)
    end)

    agent_id = "agent_#{:erlang.unique_integer([:positive])}"
    resource = "arbor://code/read/policy_bind_#{:erlang.unique_integer([:positive])}"
    Application.put_env(:arbor_security, :consensus_escalation_enabled, false)

    {:ok, _cap} =
      Security.grant_fixture(
        principal: agent_id,
        resource: resource,
        constraints: %{requires_approval: true}
      )

    arguments = %{"path" => "/approved/exact"}
    {:ok, digest} = Security.approval_argument_digest(arguments)

    %{agent_id: agent_id, resource: resource, digest: digest}
  end

  test "security regression: a receipt issued under policy X is rejected after the policy tightens to Y",
       %{agent_id: agent_id, resource: resource, digest: digest} do
    put_policy_digest(policy_digest("ask"))

    {:ok, receipt} =
      ApprovalReceiptBroker.issue_for_test(
        agent_id,
        resource,
        :execute,
        digest,
        "irq_policy_x"
      )

    put_policy_digest(policy_digest("block"))

    assert {:error, :invalid_approval_receipt} =
             Security.authorize(agent_id, resource, :execute,
               approved_invocation: receipt,
               argument_digest: digest,
               request_id: "irq_policy_x"
             )

    assert {:error, :invalid_approval_receipt} =
             ApprovalReceiptBroker.consume(
               receipt,
               agent_id,
               resource,
               :execute,
               digest,
               "irq_policy_x"
             )

    {:ok, fresh} =
      ApprovalReceiptBroker.issue_for_test(
        agent_id,
        resource,
        :execute,
        digest,
        "irq_policy_y"
      )

    assert {:ok, :authorized} =
             Security.authorize(agent_id, resource, :execute,
               approved_invocation: fresh,
               argument_digest: digest,
               request_id: "irq_policy_y"
             )
  end

  test "security regression: a receipt issued under an unchanged policy still authorizes",
       %{agent_id: agent_id, resource: resource, digest: digest} do
    put_policy_digest(policy_digest("ask"))

    {:ok, receipt} =
      ApprovalReceiptBroker.issue_for_test(
        agent_id,
        resource,
        :execute,
        digest,
        "irq_policy_stable"
      )

    assert {:ok, :authorized} =
             Security.authorize(agent_id, resource, :execute,
               approved_invocation: receipt,
               argument_digest: digest,
               request_id: "irq_policy_stable"
             )
  end

  defp put_policy_digest(digest) do
    Application.put_env(:arbor_security, :approval_policy_digest, fn _principal, _resource ->
      digest
    end)
  end

  defp restore_policy_digest(nil),
    do: Application.delete_env(:arbor_security, :approval_policy_digest)

  defp restore_policy_digest(value),
    do: Application.put_env(:arbor_security, :approval_policy_digest, value)

  defp policy_digest(label) do
    :crypto.hash(:sha256, "arbor.test.approval_policy:" <> label)
    |> Base.encode16(case: :lower)
  end
end
