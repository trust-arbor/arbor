defmodule Arbor.Contracts.Security.IdentityTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.Identity

  describe "new/1" do
    test "derives correct agent_id from public key" do
      {public_key, _private_key} = :crypto.generate_key(:eddsa, :ed25519)
      expected_id = "agent_" <> Base.encode16(:crypto.hash(:sha256, public_key), case: :lower)

      {:ok, identity} = Identity.new(public_key: public_key)

      assert identity.agent_id == expected_id
      assert identity.public_key == public_key
      assert identity.private_key == nil
      assert identity.key_version == 1
      assert %DateTime{} = identity.created_at
    end

    test "accepts optional private key" do
      {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

      {:ok, identity} = Identity.new(public_key: public_key, private_key: private_key)

      assert identity.private_key == private_key
    end

    test "rejects invalid public key size" do
      assert {:error, {:invalid_public_key_size, _, :expected, 32}} =
               Identity.new(public_key: <<1, 2, 3>>)
    end

    test "rejects invalid private key size" do
      {public_key, _private_key} = :crypto.generate_key(:eddsa, :ed25519)

      assert {:error, {:invalid_private_key_size, _, :expected, 32}} =
               Identity.new(public_key: public_key, private_key: <<1, 2, 3>>)
    end

    test "accepts custom key_version and metadata" do
      {public_key, _private_key} = :crypto.generate_key(:eddsa, :ed25519)

      {:ok, identity} =
        Identity.new(
          public_key: public_key,
          key_version: 2,
          metadata: %{node: "node_1"}
        )

      assert identity.key_version == 2
      assert identity.metadata == %{node: "node_1"}
    end
  end

  describe "generate/0" do
    test "produces valid keypair with matching agent_id" do
      {:ok, identity} = Identity.generate()

      assert String.starts_with?(identity.agent_id, "agent_")
      assert byte_size(identity.public_key) == 32
      assert byte_size(identity.private_key) == 32
      assert identity.key_version == 1

      # agent_id is deterministic from public key
      expected_id = Identity.derive_agent_id(identity.public_key)
      assert identity.agent_id == expected_id
    end

    test "generates unique identities" do
      {:ok, id1} = Identity.generate()
      {:ok, id2} = Identity.generate()

      refute id1.agent_id == id2.agent_id
      refute id1.public_key == id2.public_key
    end
  end

  describe "derive_agent_id/1" do
    test "is deterministic" do
      {public_key, _} = :crypto.generate_key(:eddsa, :ed25519)

      id1 = Identity.derive_agent_id(public_key)
      id2 = Identity.derive_agent_id(public_key)

      assert id1 == id2
    end

    test "produces agent_ prefix with 64-char hex suffix" do
      {public_key, _} = :crypto.generate_key(:eddsa, :ed25519)

      id = Identity.derive_agent_id(public_key)

      assert String.starts_with?(id, "agent_")
      hex = String.trim_leading(id, "agent_")
      assert String.length(hex) == 64
      assert String.match?(hex, ~r/^[0-9a-f]+$/)
    end
  end

  describe "public_only/1" do
    test "strips private key" do
      {:ok, identity} = Identity.generate()
      assert identity.private_key != nil

      public = Identity.public_only(identity)
      assert public.private_key == nil
      assert public.agent_id == identity.agent_id
      assert public.public_key == identity.public_key
    end
  end

  describe "name field" do
    test "name is nil by default" do
      {:ok, identity} = Identity.generate()
      assert identity.name == nil
    end

    test "accepts a name" do
      {:ok, identity} = Identity.generate(name: "code-reviewer")
      assert identity.name == "code-reviewer"
    end

    test "rejects empty string name" do
      {pk, sk} = :crypto.generate_key(:eddsa, :ed25519)
      assert {:error, :empty_name} = Identity.new(public_key: pk, private_key: sk, name: "")
    end

    test "rejects non-string name" do
      {pk, sk} = :crypto.generate_key(:eddsa, :ed25519)

      assert {:error, {:invalid_name, 42}} =
               Identity.new(public_key: pk, private_key: sk, name: 42)
    end
  end

  describe "display_name/1" do
    test "shows truncated agent_id when no name" do
      {:ok, identity} = Identity.generate()
      display = Identity.display_name(identity)

      assert String.ends_with?(display, "..")
      assert String.starts_with?(display, "agent_")
      assert String.length(display) == 18
    end

    test "shows name with short agent_id when named" do
      {:ok, identity} = Identity.generate(name: "auditor")
      display = Identity.display_name(identity)

      assert String.starts_with?(display, "auditor (agent_")
      assert String.ends_with?(display, "..)")
    end
  end

  describe "Jason encoding" do
    test "excludes private_key from JSON" do
      {:ok, identity} = Identity.generate()
      json = Jason.encode!(identity)
      decoded = Jason.decode!(json)

      refute Map.has_key?(decoded, "private_key")
      assert Map.has_key?(decoded, "agent_id")
      assert Map.has_key?(decoded, "public_key")
    end
  end
end
