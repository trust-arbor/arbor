defmodule Arbor.Security.CryptoTest do
  use ExUnit.Case, async: true

  alias Arbor.Security.Crypto

  @moduletag :fast

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

  describe "generate_encryption_keypair/0" do
    test "returns 32-byte keys" do
      {public_key, private_key} = Crypto.generate_encryption_keypair()

      assert byte_size(public_key) == 32
      assert byte_size(private_key) == 32
    end

    test "generates unique keypairs" do
      {pk1, _} = Crypto.generate_encryption_keypair()
      {pk2, _} = Crypto.generate_encryption_keypair()

      refute pk1 == pk2
    end
  end

  describe "derive_shared_secret/2" do
    test "both parties derive the same shared secret" do
      {alice_pub, alice_priv} = Crypto.generate_encryption_keypair()
      {bob_pub, bob_priv} = Crypto.generate_encryption_keypair()

      secret_alice = Crypto.derive_shared_secret(alice_priv, bob_pub)
      secret_bob = Crypto.derive_shared_secret(bob_priv, alice_pub)

      assert secret_alice == secret_bob
      assert byte_size(secret_alice) == 32
    end

    test "different keypairs produce different shared secrets" do
      {_alice_pub, alice_priv} = Crypto.generate_encryption_keypair()
      {bob_pub, _bob_priv} = Crypto.generate_encryption_keypair()
      {carol_pub, _carol_priv} = Crypto.generate_encryption_keypair()

      secret_ab = Crypto.derive_shared_secret(alice_priv, bob_pub)
      secret_ac = Crypto.derive_shared_secret(alice_priv, carol_pub)

      refute secret_ab == secret_ac
    end
  end

  describe "derive_key/3" do
    test "returns key of requested length" do
      ikm = :crypto.strong_rand_bytes(32)

      key16 = Crypto.derive_key(ikm, "test", 16)
      key32 = Crypto.derive_key(ikm, "test", 32)
      key48 = Crypto.derive_key(ikm, "test", 48)

      assert byte_size(key16) == 16
      assert byte_size(key32) == 32
      assert byte_size(key48) == 48
    end

    test "is deterministic" do
      ikm = :crypto.strong_rand_bytes(32)

      key1 = Crypto.derive_key(ikm, "info", 32)
      key2 = Crypto.derive_key(ikm, "info", 32)

      assert key1 == key2
    end

    test "different info strings produce different keys" do
      ikm = :crypto.strong_rand_bytes(32)

      key_a = Crypto.derive_key(ikm, "context-a", 32)
      key_b = Crypto.derive_key(ikm, "context-b", 32)

      refute key_a == key_b
    end

    test "defaults to 32 bytes" do
      ikm = :crypto.strong_rand_bytes(32)
      key = Crypto.derive_key(ikm, "test")
      assert byte_size(key) == 32
    end
  end

  describe "encrypt/3 and decrypt/5" do
    test "round-trip succeeds" do
      key = :crypto.strong_rand_bytes(32)
      plaintext = "secret message"

      {ciphertext, iv, tag} = Crypto.encrypt(plaintext, key)
      assert {:ok, ^plaintext} = Crypto.decrypt(ciphertext, key, iv, tag)
    end

    test "with additional authenticated data" do
      key = :crypto.strong_rand_bytes(32)
      plaintext = "secret"
      aad = "metadata"

      {ciphertext, iv, tag} = Crypto.encrypt(plaintext, key, aad)
      assert {:ok, ^plaintext} = Crypto.decrypt(ciphertext, key, iv, tag, aad)
    end

    test "fails with wrong key" do
      key1 = :crypto.strong_rand_bytes(32)
      key2 = :crypto.strong_rand_bytes(32)

      {ciphertext, iv, tag} = Crypto.encrypt("data", key1)
      assert {:error, :decryption_failed} = Crypto.decrypt(ciphertext, key2, iv, tag)
    end

    test "fails with tampered ciphertext" do
      key = :crypto.strong_rand_bytes(32)

      {ciphertext, iv, tag} = Crypto.encrypt("data", key)
      tampered = :crypto.strong_rand_bytes(byte_size(ciphertext))

      assert {:error, :decryption_failed} = Crypto.decrypt(tampered, key, iv, tag)
    end

    test "fails with tampered tag" do
      key = :crypto.strong_rand_bytes(32)

      {ciphertext, iv, _tag} = Crypto.encrypt("data", key)
      tampered_tag = :crypto.strong_rand_bytes(16)

      assert {:error, :decryption_failed} = Crypto.decrypt(ciphertext, key, iv, tampered_tag)
    end

    test "fails with wrong AAD" do
      key = :crypto.strong_rand_bytes(32)

      {ciphertext, iv, tag} = Crypto.encrypt("data", key, "correct-aad")
      assert {:error, :decryption_failed} = Crypto.decrypt(ciphertext, key, iv, tag, "wrong-aad")
    end

    test "iv is 12 bytes, tag is 16 bytes" do
      key = :crypto.strong_rand_bytes(32)
      {_ciphertext, iv, tag} = Crypto.encrypt("data", key)

      assert byte_size(iv) == 12
      assert byte_size(tag) == 16
    end
  end

  describe "seal/3 and unseal/2" do
    test "round-trip between two parties" do
      {alice_pub, alice_priv} = Crypto.generate_encryption_keypair()
      {bob_pub, bob_priv} = Crypto.generate_encryption_keypair()

      plaintext = "hello bob, from alice"

      sealed = Crypto.seal(plaintext, bob_pub, alice_priv)

      assert is_binary(sealed.ciphertext)
      assert is_binary(sealed.iv)
      assert is_binary(sealed.tag)
      assert is_binary(sealed.sender_public)
      assert sealed.sender_public == alice_pub

      assert {:ok, ^plaintext} = Crypto.unseal(sealed, bob_priv)
    end

    test "fails with wrong recipient private key" do
      {_alice_pub, alice_priv} = Crypto.generate_encryption_keypair()
      {bob_pub, _bob_priv} = Crypto.generate_encryption_keypair()
      {_carol_pub, carol_priv} = Crypto.generate_encryption_keypair()

      sealed = Crypto.seal("secret", bob_pub, alice_priv)

      # Carol can't unseal Bob's message
      assert {:error, :decryption_failed} = Crypto.unseal(sealed, carol_priv)
    end

    test "sealed messages are different each time (random IV)" do
      {_alice_pub, alice_priv} = Crypto.generate_encryption_keypair()
      {bob_pub, _bob_priv} = Crypto.generate_encryption_keypair()

      sealed1 = Crypto.seal("same message", bob_pub, alice_priv)
      sealed2 = Crypto.seal("same message", bob_pub, alice_priv)

      refute sealed1.iv == sealed2.iv
      refute sealed1.ciphertext == sealed2.ciphertext
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
