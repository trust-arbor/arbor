defmodule Arbor.Security.CryptoTest do
  use ExUnit.Case, async: true

  alias Arbor.Security.Crypto

  describe "generate_keypair/0" do
    test "returns correct key sizes" do
      {public_key, private_key} = Crypto.generate_keypair()

      assert byte_size(public_key) == 32
      assert byte_size(private_key) == 32
    end

    test "generates unique keypairs" do
      {pk1, _} = Crypto.generate_keypair()
      {pk2, _} = Crypto.generate_keypair()

      refute pk1 == pk2
    end
  end

  describe "sign/2 and verify/3" do
    test "round-trip succeeds" do
      {public_key, private_key} = Crypto.generate_keypair()
      message = "hello world"

      signature = Crypto.sign(message, private_key)
      assert Crypto.verify(message, signature, public_key)
    end

    test "rejects tampered message" do
      {public_key, private_key} = Crypto.generate_keypair()

      signature = Crypto.sign("original", private_key)
      refute Crypto.verify("tampered", signature, public_key)
    end

    test "rejects wrong public key" do
      {_pk1, sk1} = Crypto.generate_keypair()
      {pk2, _sk2} = Crypto.generate_keypair()

      signature = Crypto.sign("message", sk1)
      refute Crypto.verify("message", signature, pk2)
    end

    test "rejects tampered signature" do
      {public_key, private_key} = Crypto.generate_keypair()
      message = "data"

      signature = Crypto.sign(message, private_key)
      tampered = :crypto.strong_rand_bytes(byte_size(signature))

      refute Crypto.verify(message, tampered, public_key)
    end
  end

  describe "derive_agent_id/1" do
    test "is deterministic and prefixed" do
      {public_key, _} = Crypto.generate_keypair()

      id1 = Crypto.derive_agent_id(public_key)
      id2 = Crypto.derive_agent_id(public_key)

      assert id1 == id2
      assert String.starts_with?(id1, "agent_")
    end

    test "produces 64-char hex suffix (SHA-256)" do
      {public_key, _} = Crypto.generate_keypair()

      id = Crypto.derive_agent_id(public_key)
      hex = String.trim_leading(id, "agent_")

      assert String.length(hex) == 64
      assert String.match?(hex, ~r/^[0-9a-f]+$/)
    end

    test "different keys produce different IDs" do
      {pk1, _} = Crypto.generate_keypair()
      {pk2, _} = Crypto.generate_keypair()

      refute Crypto.derive_agent_id(pk1) == Crypto.derive_agent_id(pk2)
    end
  end

  describe "hash/1" do
    test "returns 32-byte SHA-256 digest" do
      result = Crypto.hash("test data")
      assert byte_size(result) == 32
    end

    test "is deterministic" do
      assert Crypto.hash("same") == Crypto.hash("same")
    end

    test "different inputs produce different hashes" do
      refute Crypto.hash("a") == Crypto.hash("b")
    end
  end
end
