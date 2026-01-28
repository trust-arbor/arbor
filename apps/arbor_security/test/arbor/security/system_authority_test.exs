defmodule Arbor.Security.SystemAuthorityTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.SystemAuthority
  alias Arbor.Security.Identity.Registry

  describe "lifecycle" do
    test "system authority starts and has an agent_id" do
      agent_id = SystemAuthority.agent_id()
      assert is_binary(agent_id)
      assert String.starts_with?(agent_id, "agent_")
    end

    test "public_key returns a 32-byte binary" do
      pk = SystemAuthority.public_key()
      assert is_binary(pk)
      assert byte_size(pk) == 32
    end

    test "system authority is registered in Identity.Registry" do
      agent_id = SystemAuthority.agent_id()
      assert {:ok, pk} = Registry.lookup(agent_id)
      assert pk == SystemAuthority.public_key()
    end
  end

  describe "sign_capability/1" do
    test "adds issuer_id and issuer_signature" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_test001"
        )

      {:ok, signed} = SystemAuthority.sign_capability(cap)

      assert signed.issuer_id == SystemAuthority.agent_id()
      assert is_binary(signed.issuer_signature)
      assert byte_size(signed.issuer_signature) > 0
    end

    test "preserves all original capability fields" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_test001",
          constraints: %{max_size: 100},
          delegation_depth: 5
        )

      {:ok, signed} = SystemAuthority.sign_capability(cap)

      assert signed.id == cap.id
      assert signed.resource_uri == cap.resource_uri
      assert signed.principal_id == cap.principal_id
      assert signed.constraints == cap.constraints
      assert signed.delegation_depth == cap.delegation_depth
    end
  end

  describe "verify_capability_signature/1" do
    test "accepts valid signature" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_test001"
        )

      {:ok, signed} = SystemAuthority.sign_capability(cap)
      assert :ok = SystemAuthority.verify_capability_signature(signed)
    end

    test "rejects tampered capability" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_test001"
        )

      {:ok, signed} = SystemAuthority.sign_capability(cap)

      # Tamper with the resource URI
      tampered = %{signed | resource_uri: "arbor://fs/write/evil"}

      assert {:error, :invalid_capability_signature} =
               SystemAuthority.verify_capability_signature(tampered)
    end

    test "rejects capability with random signature" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_test001",
          issuer_id: SystemAuthority.agent_id()
        )

      cap = %{cap | issuer_signature: :crypto.strong_rand_bytes(64)}

      assert {:error, :invalid_capability_signature} =
               SystemAuthority.verify_capability_signature(cap)
    end
  end
end
