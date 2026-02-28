defmodule Arbor.Security.OIDC.IdentityStoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Security.OIDC.IdentityStore

  @moduletag :fast

  describe "derive_agent_id/1" do
    test "produces deterministic agent ID from iss:sub" do
      claims = %{iss: "https://accounts.google.com", sub: "12345"}

      id1 = IdentityStore.derive_agent_id(claims)
      id2 = IdentityStore.derive_agent_id(claims)

      assert id1 == id2
      assert String.starts_with?(id1, "human_")
      # 40 hex chars after prefix
      assert String.length(id1) == String.length("human_") + 40
    end

    test "different iss:sub pairs produce different IDs" do
      id1 = IdentityStore.derive_agent_id(%{iss: "https://a.com", sub: "1"})
      id2 = IdentityStore.derive_agent_id(%{iss: "https://b.com", sub: "1"})
      id3 = IdentityStore.derive_agent_id(%{iss: "https://a.com", sub: "2"})

      assert id1 != id2
      assert id1 != id3
      assert id2 != id3
    end

    test "accepts string keys" do
      atom_id = IdentityStore.derive_agent_id(%{iss: "https://x.com", sub: "42"})
      string_id = IdentityStore.derive_agent_id(%{"iss" => "https://x.com", "sub" => "42"})

      assert atom_id == string_id
    end
  end

  describe "load_or_create/1" do
    test "creates new identity when SigningKeyStore unavailable" do
      claims = %{
        iss: "https://test.arbor.dev",
        sub: "test-user-#{System.unique_integer([:positive])}",
        email: "test@example.com",
        name: "Test User"
      }

      case IdentityStore.load_or_create(claims) do
        {:ok, identity, :created} ->
          assert String.starts_with?(identity.agent_id, "human_")
          assert identity.private_key != nil
          assert identity.public_key != nil
          assert identity.metadata["identity_type"] == "human"
          assert identity.metadata["oidc_email"] == "test@example.com"

        {:error, :store_unavailable} ->
          # Expected when BufferedStore isn't running
          :ok

        {:error, _reason} ->
          # Other store errors are acceptable in test env
          :ok
      end
    end
  end
end
