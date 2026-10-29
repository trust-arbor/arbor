defmodule Arbor.Contracts.Security.CapabilitySigningTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.Capability

  describe "signing_payload/1" do
    test "is deterministic — same capability produces same payload" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_test001",
          constraints: %{max_size: 100}
        )

      assert Capability.signing_payload(cap) == Capability.signing_payload(cap)
    end

    test "excludes issuer_signature field" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_test001"
        )

      payload1 = Capability.signing_payload(cap)
      cap_with_sig = %{cap | issuer_signature: :crypto.strong_rand_bytes(64)}
      payload2 = Capability.signing_payload(cap_with_sig)

      assert payload1 == payload2
    end

    test "includes issuer_id in payload" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_test001"
        )

      payload_without_issuer = Capability.signing_payload(cap)
      cap_with_issuer = %{cap | issuer_id: "agent_issuer001"}
      payload_with_issuer = Capability.signing_payload(cap_with_issuer)

      refute payload_without_issuer == payload_with_issuer
    end

    test "M4 security regression: signed_at is part of the signing payload" do
      # M4 (2026-02-16 review): the capability signing payload must include a
      # signature timestamp (`signed_at`) so a signature is bound to when it
      # was created. The fix added `signed_at` to the Capability struct and to
      # signing_payload/1. If `signed_at` is dropped from the payload, altering
      # it would NOT change the bytes that get signed — this test catches that
      # by asserting two capabilities that differ ONLY in signed_at produce
      # different signing payloads.
      now = DateTime.utc_now()

      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_test001"
        )

      cap_t1 = %{cap | signed_at: now}
      cap_t2 = %{cap | signed_at: DateTime.add(now, 60, :second)}

      payload_t1 = Capability.signing_payload(cap_t1)
      payload_t2 = Capability.signing_payload(cap_t2)

      refute payload_t1 == payload_t2,
             "altering signed_at must change the signing payload (M4)"

      # And a nil signed_at must differ from a set one (the field is genuinely
      # covered, not a constant).
      refute Capability.signing_payload(%{cap | signed_at: nil}) == payload_t1
    end

    test "different constraints produce different payloads" do
      {:ok, cap1} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_test001",
          constraints: %{a: 1}
        )

      {:ok, cap2} =
        Capability.new(
          id: cap1.id,
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_test001",
          granted_at: cap1.granted_at,
          constraints: %{b: 2}
        )

      refute Capability.signing_payload(cap1) == Capability.signing_payload(cap2)
    end
  end

  describe "signed?/1" do
    test "returns false for unsigned capability" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_test001"
        )

      refute Capability.signed?(cap)
    end

    test "returns false for empty binary signature" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_test001"
        )

      cap = %{cap | issuer_signature: <<>>}
      refute Capability.signed?(cap)
    end

    test "returns true for capability with signature" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_test001"
        )

      cap = %{cap | issuer_signature: :crypto.strong_rand_bytes(64)}
      assert Capability.signed?(cap)
    end
  end

  describe "delegation chain" do
    test "delegation builds correctly through delegate/3" do
      {:ok, parent} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_parent",
          delegation_depth: 3
        )

      delegation_record = %{
        delegator_id: "agent_parent",
        delegator_signature: :crypto.strong_rand_bytes(64),
        constraints: %{}
      }

      {:ok, child} =
        Capability.delegate(parent, "agent_child", delegation_record: delegation_record)

      assert child.principal_id == "agent_child"
      assert child.parent_capability_id == parent.id
      assert child.delegation_depth == 2
      assert length(child.delegation_chain) == 1
      assert hd(child.delegation_chain).delegator_id == "agent_parent"
    end

    test "delegation chain accumulates through multiple delegations" do
      {:ok, root} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_root",
          delegation_depth: 5
        )

      record1 = %{
        delegator_id: "agent_root",
        delegator_signature: :crypto.strong_rand_bytes(64),
        constraints: %{}
      }

      {:ok, child1} =
        Capability.delegate(root, "agent_child1", delegation_record: record1)

      record2 = %{
        delegator_id: "agent_child1",
        delegator_signature: :crypto.strong_rand_bytes(64),
        constraints: %{read_only: true}
      }

      {:ok, child2} =
        Capability.delegate(child1, "agent_child2", delegation_record: record2)

      assert length(child2.delegation_chain) == 2
      assert Enum.at(child2.delegation_chain, 0).delegator_id == "agent_root"
      assert Enum.at(child2.delegation_chain, 1).delegator_id == "agent_child1"
    end
  end

  describe "validate_issuer_id" do
    test "accepts nil issuer_id" do
      assert {:ok, _} =
               Capability.new(
                 resource_uri: "arbor://fs/read/docs",
                 principal_id: "agent_test001"
               )
    end

    test "accepts agent_ prefixed issuer_id" do
      assert {:ok, _} =
               Capability.new(
                 resource_uri: "arbor://fs/read/docs",
                 principal_id: "agent_test001",
                 issuer_id: "agent_issuer001"
               )
    end

    test "accepts system_authority issuer_id" do
      assert {:ok, _} =
               Capability.new(
                 resource_uri: "arbor://fs/read/docs",
                 principal_id: "agent_test001",
                 issuer_id: "system_authority"
               )
    end

    test "rejects invalid issuer_id" do
      assert {:error, {:invalid_issuer_id, "bad_issuer"}} =
               Capability.new(
                 resource_uri: "arbor://fs/read/docs",
                 principal_id: "agent_test001",
                 issuer_id: "bad_issuer"
               )
    end
  end
end
