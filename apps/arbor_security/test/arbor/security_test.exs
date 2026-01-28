defmodule Arbor.SecurityTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Security

  setup do
    # Create a unique agent ID for each test
    agent_id = "agent_#{:erlang.unique_integer([:positive])}"
    {:ok, agent_id: agent_id}
  end

  describe "authorize/4" do
    test "returns unauthorized without capability", %{agent_id: agent_id} do
      assert {:error, :unauthorized} =
               Security.authorize(agent_id, "arbor://fs/read/docs")
    end

    test "returns authorized with valid capability", %{agent_id: agent_id} do
      {:ok, _cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://fs/read/docs"
        )

      assert {:ok, :authorized} =
               Security.authorize(agent_id, "arbor://fs/read/docs")
    end
  end

  describe "can?/2" do
    test "returns false without capability", %{agent_id: agent_id} do
      refute Security.can?(agent_id, "arbor://fs/read/docs")
    end

    test "returns true with valid capability", %{agent_id: agent_id} do
      {:ok, _cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://fs/read/docs"
        )

      assert Security.can?(agent_id, "arbor://fs/read/docs")
    end
  end

  describe "grant/1 and revoke/2" do
    test "grants capability", %{agent_id: agent_id} do
      {:ok, cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://fs/read/project"
        )

      assert cap.principal_id == agent_id
      assert cap.resource_uri == "arbor://fs/read/project"
    end

    test "revokes capability", %{agent_id: agent_id} do
      {:ok, cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://fs/write/temp"
        )

      assert Security.can?(agent_id, "arbor://fs/write/temp")

      :ok = Security.revoke(cap.id)

      refute Security.can?(agent_id, "arbor://fs/write/temp")
    end
  end

  describe "list_capabilities/2" do
    test "lists capabilities for agent", %{agent_id: agent_id} do
      {:ok, _} =
        Security.grant(principal: agent_id, resource: "arbor://fs/read/a")

      {:ok, _} =
        Security.grant(principal: agent_id, resource: "arbor://fs/read/b")

      {:ok, caps} = Security.list_capabilities(agent_id)

      assert length(caps) == 2
    end
  end

  describe "healthy?/0" do
    test "returns true when system is running" do
      assert Security.healthy?() == true
    end
  end

  describe "stats/0" do
    test "returns capability and identity statistics" do
      stats = Security.stats()

      assert Map.has_key?(stats, :capabilities)
      assert Map.has_key?(stats, :identities)
      assert Map.has_key?(stats, :healthy)
      assert Map.has_key?(stats, :system_authority_id)
      assert is_binary(stats.system_authority_id)
    end
  end

  # ===========================================================================
  # Identity facade tests
  # ===========================================================================

  describe "generate_identity/1" do
    test "returns identity with keypair" do
      {:ok, identity} = Security.generate_identity()

      assert String.starts_with?(identity.agent_id, "agent_")
      assert byte_size(identity.public_key) == 32
      assert byte_size(identity.private_key) == 32
    end
  end

  describe "register_identity/1 and lookup_public_key/1" do
    test "round-trip works" do
      {:ok, identity} = Security.generate_identity()
      :ok = Security.register_identity(identity)

      assert {:ok, pk} = Security.lookup_public_key(identity.agent_id)
      assert pk == identity.public_key
    end
  end

  describe "verify_request/1" do
    test "valid request verifies successfully" do
      {:ok, identity} = Security.generate_identity()
      :ok = Security.register_identity(identity)

      {:ok, signed} =
        SignedRequest.sign(
          "payload",
          identity.agent_id,
          identity.private_key
        )

      assert {:ok, agent_id} = Security.verify_request(signed)
      assert agent_id == identity.agent_id
    end
  end

  describe "authorize/4 with identity verification" do
    test "succeeds with valid signed_request for registered agent with capability" do
      {:ok, identity} = Security.generate_identity()
      :ok = Security.register_identity(identity)

      {:ok, _cap} =
        Security.grant(
          principal: identity.agent_id,
          resource: "arbor://fs/read/docs"
        )

      {:ok, signed} =
        SignedRequest.sign(
          "authorize",
          identity.agent_id,
          identity.private_key
        )

      assert {:ok, :authorized} =
               Security.authorize(identity.agent_id, "arbor://fs/read/docs", nil,
                 signed_request: signed,
                 verify_identity: true
               )
    end

    test "fails with invalid signed_request" do
      {:ok, identity} = Security.generate_identity()
      :ok = Security.register_identity(identity)

      {:ok, _cap} =
        Security.grant(
          principal: identity.agent_id,
          resource: "arbor://fs/read/docs"
        )

      {:ok, signed} =
        SignedRequest.sign(
          "authorize",
          identity.agent_id,
          identity.private_key
        )

      # Tamper with signature
      tampered = %{signed | signature: :crypto.strong_rand_bytes(byte_size(signed.signature))}

      assert {:error, :invalid_signature} =
               Security.authorize(identity.agent_id, "arbor://fs/read/docs", nil,
                 signed_request: tampered,
                 verify_identity: true
               )
    end

    test "works without signed_request (backward compatible)", %{agent_id: agent_id} do
      {:ok, _cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://fs/read/legacy"
        )

      # No signed_request, identity verification not forced
      assert {:ok, :authorized} =
               Security.authorize(agent_id, "arbor://fs/read/legacy")
    end
  end

  # ===========================================================================
  # Phase 2: Capability signing integration tests
  # ===========================================================================

  describe "grant/1 signs capabilities" do
    test "granted capabilities have issuer_id and issuer_signature", %{agent_id: agent_id} do
      {:ok, cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://fs/read/signed"
        )

      assert is_binary(cap.issuer_id)
      assert String.starts_with?(cap.issuer_id, "agent_")
      assert is_binary(cap.issuer_signature)
      assert byte_size(cap.issuer_signature) > 0
    end

    test "granted capability signature is valid", %{agent_id: agent_id} do
      {:ok, cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://fs/read/verified"
        )

      assert :ok =
               Arbor.Security.SystemAuthority.verify_capability_signature(cap)
    end
  end

  describe "find_authorizing returns signed capabilities" do
    test "authorized capability is signed", %{agent_id: agent_id} do
      {:ok, _cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://fs/read/found"
        )

      assert {:ok, :authorized} =
               Security.authorize(agent_id, "arbor://fs/read/found")
    end
  end

  describe "tampered capability signature" do
    test "authorization fails for tampered capability", %{agent_id: agent_id} do
      {:ok, cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://fs/read/tamper"
        )

      # Tamper with the stored capability by revoking and putting a modified version
      :ok = Security.revoke(cap.id)

      tampered = %{cap | resource_uri: "arbor://fs/write/evil"}
      :ok = Arbor.Security.CapabilityStore.put(tampered)

      # The tampered capability should fail signature verification
      assert {:error, :unauthorized} =
               Security.authorize(agent_id, "arbor://fs/write/evil")
    end
  end

  describe "delegation through facade" do
    test "produces signed delegation chain", %{agent_id: agent_id} do
      {:ok, identity} = Security.generate_identity()
      :ok = Security.register_identity(identity)

      {:ok, parent_cap} =
        Security.grant(
          principal: identity.agent_id,
          resource: "arbor://fs/read/delegated"
        )

      {:ok, delegated} =
        Security.delegate(parent_cap.id, agent_id, delegator_private_key: identity.private_key)

      assert delegated.principal_id == agent_id
      assert delegated.parent_capability_id == parent_cap.id
      assert is_binary(delegated.issuer_signature)
      assert length(delegated.delegation_chain) == 1
      assert hd(delegated.delegation_chain).delegator_id == identity.agent_id
    end
  end

  describe "backward compatibility" do
    test "unsigned capabilities work when capability_signing_required? is false",
         %{agent_id: agent_id} do
      # Directly store an unsigned capability (simulating pre-Phase 2 data)
      {:ok, unsigned_cap} =
        Arbor.Contracts.Security.Capability.new(
          resource_uri: "arbor://fs/read/legacy_unsigned",
          principal_id: agent_id
        )

      :ok = Arbor.Security.CapabilityStore.put(unsigned_cap)

      # Default config has capability_signing_required: false
      assert {:ok, :authorized} =
               Security.authorize(agent_id, "arbor://fs/read/legacy_unsigned")
    end
  end
end
