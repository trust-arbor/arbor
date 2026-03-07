defmodule Arbor.Security.InvocationReceiptIntegrationTest do
  use ExUnit.Case

  alias Arbor.Contracts.Security.InvocationReceipt
  alias Arbor.Security.SystemAuthority

  describe "SystemAuthority.sign_receipt/1" do
    @tag :fast
    test "signs a receipt and verification succeeds" do
      {:ok, receipt} =
        InvocationReceipt.new(
          capability_id: "cap_test123",
          principal_id: "agent_test001",
          resource_uri: "arbor://fs/read/docs",
          action: :read,
          delegation_chain: [%{delegator: "agent_parent", delegatee: "agent_test001"}],
          session_id: "session_abc",
          task_id: "task_001"
        )

      {:ok, signed} = SystemAuthority.sign_receipt(receipt)

      assert InvocationReceipt.signed?(signed)
      assert signed.issuer_id != nil

      # Verify with system authority's public key
      pub_key = SystemAuthority.public_key()
      assert :ok = InvocationReceipt.verify(signed, pub_key)
    end

    @tag :fast
    test "tampering after signing invalidates receipt" do
      {:ok, receipt} =
        InvocationReceipt.new(
          capability_id: "cap_test456",
          principal_id: "agent_test002",
          resource_uri: "arbor://shell/exec/ls"
        )

      {:ok, signed} = SystemAuthority.sign_receipt(receipt)
      pub_key = SystemAuthority.public_key()

      # Tamper
      tampered = %{signed | principal_id: "agent_evil"}
      assert {:error, :invalid_receipt_signature} = InvocationReceipt.verify(tampered, pub_key)
    end

    @tag :fast
    test "receipt includes delegation chain from capability" do
      chain = [
        %{delegator: "agent_root", delegatee: "agent_mid", timestamp: "2026-03-06T18:00:00Z"},
        %{delegator: "agent_mid", delegatee: "agent_leaf", timestamp: "2026-03-06T18:01:00Z"}
      ]

      {:ok, receipt} =
        InvocationReceipt.new(
          capability_id: "cap_delegated",
          principal_id: "agent_leaf",
          resource_uri: "arbor://fs/read/docs",
          delegation_chain: chain
        )

      {:ok, signed} = SystemAuthority.sign_receipt(receipt)
      assert length(signed.delegation_chain) == 2

      # Verify — chain is part of the signed payload
      pub_key = SystemAuthority.public_key()
      assert :ok = InvocationReceipt.verify(signed, pub_key)

      # Tamper with chain
      tampered = %{signed | delegation_chain: []}
      assert {:error, :invalid_receipt_signature} = InvocationReceipt.verify(tampered, pub_key)
    end
  end
end
