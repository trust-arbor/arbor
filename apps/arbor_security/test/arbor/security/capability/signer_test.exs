defmodule Arbor.Security.Capability.SignerTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security.Capability.Signer

  setup do
    {:ok, identity} = Identity.generate()
    {:ok, identity2} = Identity.generate()

    {:ok, cap} =
      Capability.new(
        resource_uri: "arbor://fs/read/docs",
        principal_id: "agent_test001",
        issuer_id: identity.agent_id
      )

    {:ok, identity: identity, identity2: identity2, cap: cap}
  end

  describe "sign/2 + verify/2 round-trip" do
    test "sign then verify succeeds", %{cap: cap, identity: id} do
      signed = Signer.sign(cap, id.private_key)

      assert is_binary(signed.issuer_signature)
      assert byte_size(signed.issuer_signature) > 0
      assert :ok = Signer.verify(signed, id.public_key)
    end
  end

  describe "verify/2" do
    test "rejects wrong key", %{cap: cap, identity: id, identity2: id2} do
      signed = Signer.sign(cap, id.private_key)

      assert {:error, :invalid_capability_signature} =
               Signer.verify(signed, id2.public_key)
    end

    test "rejects tampered capability", %{cap: cap, identity: id} do
      signed = Signer.sign(cap, id.private_key)
      tampered = %{signed | resource_uri: "arbor://fs/write/evil"}

      assert {:error, :invalid_capability_signature} =
               Signer.verify(tampered, id.public_key)
    end

    test "rejects nil signature", %{cap: cap, identity: id} do
      assert {:error, :invalid_capability_signature} =
               Signer.verify(cap, id.public_key)
    end
  end

  describe "canonical_payload/1" do
    test "is deterministic", %{cap: cap} do
      assert Signer.canonical_payload(cap) == Signer.canonical_payload(cap)
    end

    test "changes when capability fields change", %{cap: cap} do
      payload1 = Signer.canonical_payload(cap)
      modified = %{cap | resource_uri: "arbor://fs/write/other"}
      payload2 = Signer.canonical_payload(modified)

      refute payload1 == payload2
    end
  end

  describe "sign_delegation/3" do
    test "produces valid delegation record", %{identity: id} do
      {:ok, parent} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: id.agent_id,
          delegation_depth: 3
        )

      {:ok, child} = Capability.delegate(parent, "agent_child001")

      record = Signer.sign_delegation(parent, child, id.private_key)

      assert record.delegator_id == id.agent_id
      assert is_binary(record.delegator_signature)
      assert is_map(record.constraints)
    end
  end

  describe "verify_delegation_chain/2" do
    test "accepts empty chain", %{cap: cap} do
      assert :ok = Signer.verify_delegation_chain(cap, fn _id -> {:error, :not_found} end)
    end

    test "accepts valid chain", %{identity: id} do
      {:ok, parent} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: id.agent_id,
          delegation_depth: 3
        )

      {:ok, child} = Capability.delegate(parent, "agent_child001")
      record = Signer.sign_delegation(parent, child, id.private_key)

      cap_with_chain = %{child | delegation_chain: [record]}

      lookup = fn
        agent_id when agent_id == id.agent_id -> {:ok, id.public_key}
        _ -> {:error, :not_found}
      end

      assert :ok = Signer.verify_delegation_chain(cap_with_chain, lookup)
    end

    test "rejects broken chain", %{identity: id, identity2: id2} do
      {:ok, parent} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: id.agent_id,
          delegation_depth: 3
        )

      {:ok, child} = Capability.delegate(parent, "agent_child001")

      # Sign with id's key but claim it's from id2
      record = Signer.sign_delegation(parent, child, id.private_key)
      bad_record = %{record | delegator_id: id2.agent_id}

      cap_with_chain = %{child | delegation_chain: [bad_record]}

      lookup = fn
        agent_id when agent_id == id2.agent_id -> {:ok, id2.public_key}
        _ -> {:error, :not_found}
      end

      assert {:error, :broken_delegation_chain} =
               Signer.verify_delegation_chain(cap_with_chain, lookup)
    end

    test "rejects chain with unknown delegator", %{identity: id} do
      {:ok, parent} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: id.agent_id,
          delegation_depth: 3
        )

      {:ok, child} = Capability.delegate(parent, "agent_child001")
      record = Signer.sign_delegation(parent, child, id.private_key)

      cap_with_chain = %{child | delegation_chain: [record]}

      # All lookups fail
      lookup = fn _id -> {:error, :not_found} end

      assert {:error, :broken_delegation_chain} =
               Signer.verify_delegation_chain(cap_with_chain, lookup)
    end
  end
end
