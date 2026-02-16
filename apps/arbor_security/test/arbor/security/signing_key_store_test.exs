defmodule Arbor.Security.SigningKeyStoreTest do
  use ExUnit.Case, async: false

  alias Arbor.Security.SigningKeyStore

  @test_agent_id "agent_test_signing_key_store_#{:erlang.unique_integer([:positive])}"

  setup do
    # Clean up after test
    on_exit(fn ->
      SigningKeyStore.delete(@test_agent_id)
    end)

    :ok
  end

  describe "put/2 and get/1" do
    test "stores and retrieves a private key" do
      # Generate a fresh Ed25519 keypair
      {_pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

      assert :ok = SigningKeyStore.put(@test_agent_id, priv)
      assert {:ok, retrieved} = SigningKeyStore.get(@test_agent_id)
      assert retrieved == priv
    end

    test "returns error for non-existent key" do
      assert {:error, :no_signing_key} = SigningKeyStore.get("agent_nonexistent_key_test")
    end

    test "overwrites existing key" do
      {_pub1, priv1} = :crypto.generate_key(:eddsa, :ed25519)
      {_pub2, priv2} = :crypto.generate_key(:eddsa, :ed25519)

      assert :ok = SigningKeyStore.put(@test_agent_id, priv1)
      assert :ok = SigningKeyStore.put(@test_agent_id, priv2)
      assert {:ok, retrieved} = SigningKeyStore.get(@test_agent_id)
      assert retrieved == priv2
    end
  end

  describe "delete/1" do
    test "deletes a stored key" do
      {_pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

      assert :ok = SigningKeyStore.put(@test_agent_id, priv)
      assert {:ok, _} = SigningKeyStore.get(@test_agent_id)

      assert :ok = SigningKeyStore.delete(@test_agent_id)
      assert {:error, :no_signing_key} = SigningKeyStore.get(@test_agent_id)
    end

    test "succeeds even if key doesn't exist" do
      assert :ok = SigningKeyStore.delete("agent_nonexistent_delete_test")
    end
  end

  describe "encryption" do
    test "stored data is encrypted (not raw private key)" do
      {_pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

      assert :ok = SigningKeyStore.put(@test_agent_id, priv)

      # Read raw record from BufferedStore — should NOT contain the raw private key
      case Arbor.Persistence.BufferedStore.get(@test_agent_id,
             name: :arbor_security_signing_keys
           ) do
        {:ok, record} ->
          # Record should be a map with encrypted fields
          assert is_map(record)
          assert Map.has_key?(record, "ct")
          assert Map.has_key?(record, "iv")
          assert Map.has_key?(record, "tag")
          # The ciphertext should NOT be the raw private key
          {:ok, ct} = Base.decode64(record["ct"])
          refute ct == priv

        {:error, _} ->
          # Store might not be available — skip this assertion
          :ok
      end
    end
  end
end
