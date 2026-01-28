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
end
