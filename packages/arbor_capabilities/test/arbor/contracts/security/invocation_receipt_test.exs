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

    @tag :fast
    test "rejects a non-atom action (security regression: it crashed the signer)" do
      assert {:error, :invalid_action} =
               InvocationReceipt.new(@valid_attrs ++ [action: %{action: :execute}])

      assert {:error, :invalid_action} = InvocationReceipt.new(@valid_attrs ++ [action: "read"])
      assert {:ok, %{action: nil}} = InvocationReceipt.new(@valid_attrs ++ [action: nil])
    end
  end

  describe "signing_payload/1" do
    @tag :fast
    test "produces deterministic payload for same receipt" do
      {:ok, receipt} = InvocationReceipt.new(@valid_attrs)

      assert InvocationReceipt.signing_payload(receipt) ==
               InvocationReceipt.signing_payload(receipt)
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

    @tag :fast
    test "encodes a real delegation record's constraints map (security regression)" do
      # Shape produced by Signer.sign_delegation/3; interpolating the map raised.
      record = %{
        delegator_id: "agent_parent",
        delegator_signature: :crypto.strong_rand_bytes(64),
        constraints: %{rate_limit: 10, allowed_paths: ["/a", "/b"], nested: %{z: 1, a: 2}},
        delegated_at: ~U[2026-09-28 12:00:00Z]
      }

      {:ok, receipt} = InvocationReceipt.new(@valid_attrs ++ [delegation_chain: [record]])
      payload = InvocationReceipt.signing_payload(receipt)
      assert payload == InvocationReceipt.signing_payload(receipt)

      loosened = %{record | constraints: Map.put(record.constraints, :rate_limit, 1_000)}

      refute payload ==
               InvocationReceipt.signing_payload(%{receipt | delegation_chain: [loosened]})
    end

    @tag :fast
    test "pins the v2 byte layout (known answer)" do
      # Every stored v2 receipt verifies against exactly these bytes. A change
      # here needs a new @signing_version and a decision record, not an edit.
      {:ok, receipt} =
        InvocationReceipt.new(
          @valid_attrs ++
            [
              action: :read,
              task_id: "task_1",
              delegation_chain: [%{delegator: "agent_a", delegatee: "agent_b"}]
            ]
        )

      receipt = %{
        receipt
        | id: "rcpt_kat",
          nonce: <<0::128>>,
          timestamp: ~U[2026-10-01 12:00:00Z],
          issuer_id: "agent_authority"
      }

      expected =
        <<20::32, "arbor-receipt-sig-v2">> <>
          <<?b, 8::32, "rcpt_kat">> <>
          <<?b, 10::32, "cap_abc123">> <>
          <<?b, 13::32, "agent_test001">> <>
          <<?b, 20::32, "arbor://fs/read/docs">> <>
          <<?a, 4::32, "read">> <>
          <<?a, 7::32, "granted">> <>
          <<?d, 37::32, ?b, 20::32, "2026-10-01T12:00:00Z", ?b, 7::32, "Etc/UTC">> <>
          <<?b, 16::32, 0::128>> <>
          <<?a, 3::32, "nil">> <>
          <<?b, 6::32, "task_1">> <>
          <<?b, 15::32, "agent_authority">> <>
          <<?l, 57::32, ?m, 52::32>> <>
          <<?a, 9::32, "delegatee", ?b, 7::32, "agent_b">> <>
          <<?a, 9::32, "delegator", ?b, 7::32, "agent_a">>

      assert InvocationReceipt.signing_payload(receipt) == expected
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

      # issuer_id is part of the signing payload, so it must be set BEFORE signing.
      receipt = %{receipt | issuer_id: "agent_authority"}

      {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
      payload = InvocationReceipt.signing_payload(receipt)
      signature = :crypto.sign(:eddsa, :sha512, payload, [priv, :ed25519])

      signed = %{receipt | signature: signature}
      assert :ok = InvocationReceipt.verify(signed, pub)
    end

    @tag :fast
    test "tampered receipt fails verification" do
      {:ok, receipt} = InvocationReceipt.new(@valid_attrs)
      receipt = %{receipt | issuer_id: "agent_authority"}

      {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
      payload = InvocationReceipt.signing_payload(receipt)
      signature = :crypto.sign(:eddsa, :sha512, payload, [priv, :ed25519])

      signed = %{receipt | signature: signature}

      # Tamper with the resource_uri
      tampered = %{signed | resource_uri: "arbor://fs/write/secrets"}
      assert {:error, :invalid_receipt_signature} = InvocationReceipt.verify(tampered, pub)
    end

    @tag :fast
    test "issuer_id is part of the signing payload (security regression)" do
      # Two receipts differing only in issuer_id must produce different payloads,
      # otherwise issuer_id is unsigned and can be relabelled freely.
      {:ok, receipt} = InvocationReceipt.new(@valid_attrs)
      a = InvocationReceipt.signing_payload(%{receipt | issuer_id: "agent_a"})
      b = InvocationReceipt.signing_payload(%{receipt | issuer_id: "agent_b"})
      refute a == b
    end

    @tag :fast
    test "tampering issuer_id fails verification (issuer_id is signed — security regression)" do
      {:ok, receipt} = InvocationReceipt.new(@valid_attrs)
      receipt = %{receipt | issuer_id: "agent_authority"}

      {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
      payload = InvocationReceipt.signing_payload(receipt)
      signature = :crypto.sign(:eddsa, :sha512, payload, [priv, :ed25519])
      signed = %{receipt | signature: signature}

      assert :ok = InvocationReceipt.verify(signed, pub)

      # Relabel the issuer — must now break the signature.
      tampered = %{signed | issuer_id: "agent_attacker"}
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

    @tag :fast
    test "an unencodable tampered field is rejected, not raised" do
      {:ok, receipt} = InvocationReceipt.new(@valid_attrs)
      receipt = %{receipt | issuer_id: "agent_authority"}

      {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
      payload = InvocationReceipt.signing_payload(receipt)
      signature = :crypto.sign(:eddsa, :sha512, payload, [priv, :ed25519])
      tampered = %{receipt | signature: signature, action: %{action: :execute}}

      assert {:error, :invalid_receipt_signature} = InvocationReceipt.verify(tampered, pub)
    end
  end

  describe "signing_payload/1 chain boundaries (security regression)" do
    # Before receipt payload v2 the delegation chain was signed as `k=v` pairs
    # joined with "," and records joined with ";", unescaped and untyped. A
    # delegator signature is 64 raw bytes, and maps were signed as their JSON
    # text, so whoever presented a signed receipt could re-shape its chain
    # into a different one with the same signed bytes and `verify/2` still
    # returned :ok. Each case below verified against the other chain.

    setup do
      {:ok, receipt} = InvocationReceipt.new(@valid_attrs ++ [action: :read])
      %{receipt: %{receipt | issuer_id: "agent_authority"}}
    end

    @tag :fast
    test "two delegation records cannot be re-presented as one", %{receipt: receipt} do
      root = delegation_record("agent_root", %{})
      middle = delegation_record("agent_middle", %{rate_limit: 5})

      # The second record hidden inside the first record's signature bytes.
      merged = %{
        root
        | delegator_signature: root.delegator_signature <> ";" <> legacy_record_text(middle)
      }

      assert_signature_binds_chain(receipt, [root, middle], [merged])
    end

    @tag :fast
    test "a delegation value cannot absorb the field after it", %{receipt: receipt} do
      record = delegation_record("agent_root", %{})

      absorbed =
        record
        |> Map.delete(:delegator_signature)
        |> Map.put(
          :delegator_id,
          "agent_root,delegator_signature=" <> record.delegator_signature
        )

      assert_signature_binds_chain(receipt, [record], [absorbed])
    end

    @tag :fast
    test "a constraints map is not interchangeable with its JSON text", %{receipt: receipt} do
      record = delegation_record("agent_root", %{rate_limit: 5})
      stringly = %{record | constraints: ~s([["rate_limit",5]])}

      assert_signature_binds_chain(receipt, [record], [stringly])
    end

    @tag :fast
    test "atom keys are not interchangeable with string keys", %{receipt: receipt} do
      record = delegation_record("agent_root", %{rate_limit: 5})
      # A reader of `record.constraints` sees no constraints on this copy.
      string_keyed = Map.new(record, fn {key, value} -> {Atom.to_string(key), value} end)

      assert_signature_binds_chain(receipt, [record], [string_keyed])
    end

    @tag :fast
    test "an absent optional field is not interchangeable with an empty one",
         %{receipt: receipt} do
      a = InvocationReceipt.signing_payload(%{receipt | session_id: nil})
      b = InvocationReceipt.signing_payload(%{receipt | session_id: ""})
      refute a == b
    end

    @tag :fast
    test "the payload is domain-separated by its signing version", %{receipt: receipt} do
      version = InvocationReceipt.signing_version()
      size = byte_size(version)

      assert <<^size::32, ^version::binary-size(size), _rest::binary>> =
               InvocationReceipt.signing_payload(receipt)
    end
  end

  describe "signing_payload/1 encodability" do
    @tag :fast
    test "a receipt whose chain holds a term with no canonical encoding is refused" do
      {:ok, receipt} = InvocationReceipt.new(@valid_attrs)
      bad = %{receipt | delegation_chain: [%{delegator_id: "agent_root", ref: make_ref()}]}

      assert_raise ArgumentError, fn -> InvocationReceipt.signing_payload(bad) end
    end

    @tag :fast
    test "a non-atom action is refused" do
      {:ok, receipt} = InvocationReceipt.new(@valid_attrs)

      assert_raise ArgumentError, fn ->
        InvocationReceipt.signing_payload(%{receipt | action: %{action: :execute}})
      end
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

  # Shaped like `Arbor.Security.Capability.Signer.sign_delegation/3` output.
  defp delegation_record(delegator_id, constraints) do
    %{
      delegator_id: delegator_id,
      delegator_signature: :crypto.strong_rand_bytes(64),
      constraints: constraints,
      delegated_at: ~U[2026-10-01 12:00:00.000000Z]
    }
  end

  # How the unversioned (v1) encoder rendered one record: keys sorted, values
  # interpolated, maps as key-sorted JSON pair lists.
  defp legacy_record_text(record) do
    record
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join(",", fn
      {key, value} when is_map(value) and not is_struct(value) ->
        "#{key}=#{Jason.encode!(legacy_pairs(value))}"

      {key, value} ->
        "#{key}=#{value}"
    end)
  end

  defp legacy_pairs(map) when is_map(map) and not is_struct(map),
    do: map |> Enum.map(fn {k, v} -> [to_string(k), legacy_pairs(v)] end) |> Enum.sort()

  defp legacy_pairs(other), do: other

  # Sign the receipt over `chain`, then present the same signature with
  # `other_chain`: the payloads must differ and only the signed chain verifies.
  defp assert_signature_binds_chain(receipt, chain, other_chain) do
    signed_receipt = %{receipt | delegation_chain: chain}
    presented = %{receipt | delegation_chain: other_chain}

    refute InvocationReceipt.signing_payload(signed_receipt) ==
             InvocationReceipt.signing_payload(presented)

    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    payload = InvocationReceipt.signing_payload(signed_receipt)
    signature = :crypto.sign(:eddsa, :sha512, payload, [priv, :ed25519])

    assert :ok = InvocationReceipt.verify(%{signed_receipt | signature: signature}, pub)

    assert {:error, :invalid_receipt_signature} =
             InvocationReceipt.verify(%{presented | signature: signature}, pub)
  end
end
