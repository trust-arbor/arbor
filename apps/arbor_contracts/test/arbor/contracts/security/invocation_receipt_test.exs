defmodule Arbor.Contracts.Security.InvocationReceiptTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.InvocationReceipt

  @valid_attrs [
    capability_id: "cap_abc123",
    principal_id: "agent_test001",
    resource_uri: "arbor://fs/read/docs"
  ]

  describe "new/1" do
    @tag :fast
    test "creates a receipt with required fields" do
      {:ok, receipt} = InvocationReceipt.new(@valid_attrs)
      assert String.starts_with?(receipt.id, "rcpt_")
      assert receipt.capability_id == "cap_abc123"
      assert receipt.principal_id == "agent_test001"
      assert receipt.resource_uri == "arbor://fs/read/docs"
      assert receipt.result == :granted
      assert %DateTime{} = receipt.timestamp
      assert byte_size(receipt.nonce) == 16
      assert receipt.delegation_chain == []
      assert receipt.signature == nil
    end

    @tag :fast
    test "creates receipt with optional fields" do
      chain = [%{delegator: "agent_parent", delegatee: "agent_test001"}]

      {:ok, receipt} =
        InvocationReceipt.new(
          @valid_attrs ++
            [
              action: :read,
              result: :pending_approval,
              delegation_chain: chain,
              session_id: "session_abc",
              task_id: "task_001"
            ]
        )

      assert receipt.action == :read
      assert receipt.result == :pending_approval
      assert receipt.delegation_chain == chain
      assert receipt.session_id == "session_abc"
      assert receipt.task_id == "task_001"
    end

    @tag :fast
    test "each receipt gets a unique id and nonce" do
      {:ok, r1} = InvocationReceipt.new(@valid_attrs)
      {:ok, r2} = InvocationReceipt.new(@valid_attrs)
      refute r1.id == r2.id
      refute r1.nonce == r2.nonce
    end
  end

  describe "signing_payload/1" do
    @tag :fast
    test "produces deterministic payload for same receipt" do
      {:ok, receipt} = InvocationReceipt.new(@valid_attrs)
      assert InvocationReceipt.signing_payload(receipt) == InvocationReceipt.signing_payload(receipt)
    end

    @tag :fast
    test "different receipts produce different payloads" do
      {:ok, r1} = InvocationReceipt.new(@valid_attrs)
      {:ok, r2} = InvocationReceipt.new(@valid_attrs)
      # Different nonces/ids → different payloads
      refute InvocationReceipt.signing_payload(r1) == InvocationReceipt.signing_payload(r2)
    end

    @tag :fast
    test "includes delegation chain in payload" do
      {:ok, r1} = InvocationReceipt.new(@valid_attrs ++ [delegation_chain: []])

      {:ok, r2} =
        InvocationReceipt.new(
          @valid_attrs ++ [delegation_chain: [%{delegator: "agent_a", delegatee: "agent_b"}]]
        )

      # Force same id/nonce/timestamp for comparison
      r2 = %{r2 | id: r1.id, nonce: r1.nonce, timestamp: r1.timestamp}
      refute InvocationReceipt.signing_payload(r1) == InvocationReceipt.signing_payload(r2)
    end
  end

  describe "verify/2" do
    @tag :fast
    test "unsigned receipt fails verification" do
      {:ok, receipt} = InvocationReceipt.new(@valid_attrs)
      fake_key = :crypto.strong_rand_bytes(32)
      assert {:error, :invalid_receipt_signature} = InvocationReceipt.verify(receipt, fake_key)
    end

    @tag :fast
    test "correctly signed receipt passes verification" do
      {:ok, receipt} = InvocationReceipt.new(@valid_attrs)

      # Sign with a test keypair
      {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
      payload = InvocationReceipt.signing_payload(receipt)
      signature = :crypto.sign(:eddsa, :sha512, payload, [priv, :ed25519])

      signed = %{receipt | signature: signature, issuer_id: "agent_authority"}
      assert :ok = InvocationReceipt.verify(signed, pub)
    end

    @tag :fast
    test "tampered receipt fails verification" do
      {:ok, receipt} = InvocationReceipt.new(@valid_attrs)

      {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
      payload = InvocationReceipt.signing_payload(receipt)
      signature = :crypto.sign(:eddsa, :sha512, payload, [priv, :ed25519])

      signed = %{receipt | signature: signature, issuer_id: "agent_authority"}

      # Tamper with the resource_uri
      tampered = %{signed | resource_uri: "arbor://fs/write/secrets"}
      assert {:error, :invalid_receipt_signature} = InvocationReceipt.verify(tampered, pub)
    end

    @tag :fast
    test "wrong key fails verification" do
      {:ok, receipt} = InvocationReceipt.new(@valid_attrs)

      {_pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
      {wrong_pub, _} = :crypto.generate_key(:eddsa, :ed25519)
      payload = InvocationReceipt.signing_payload(receipt)
      signature = :crypto.sign(:eddsa, :sha512, payload, [priv, :ed25519])

      signed = %{receipt | signature: signature}
      assert {:error, :invalid_receipt_signature} = InvocationReceipt.verify(signed, wrong_pub)
    end
  end

  describe "signed?/1" do
    @tag :fast
    test "unsigned receipt returns false" do
      {:ok, receipt} = InvocationReceipt.new(@valid_attrs)
      refute InvocationReceipt.signed?(receipt)
    end

    @tag :fast
    test "signed receipt returns true" do
      {:ok, receipt} = InvocationReceipt.new(@valid_attrs)
      signed = %{receipt | signature: :crypto.strong_rand_bytes(64)}
      assert InvocationReceipt.signed?(signed)
    end
  end
end
