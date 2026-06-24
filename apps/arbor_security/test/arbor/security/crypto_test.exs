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

    test "pure Ed25519 :none digest — pinned cross-version vector (C9 guard)" do
      # `Crypto.sign/2` uses the `:none` digest argument for pure Ed25519
      # (RFC 8032 hashes internally). OTP has historically ignored the digest
      # parameter for eddsa, so on the current OTP `:none` and `:sha512` yield
      # identical bytes — which is why the C9 swap is no-migration. This pins
      # a deterministic vector (fixed seed → fixed signature) so that if a
      # future OTP ever changes eddsa to honor a prehash digest, the signature
      # changes and THIS TEST FAILS, surfacing the drift instead of silently
      # breaking interop / verification of stored signatures.
      seed = :binary.copy(<<0x42>>, 32)
      {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519, seed)
      message = "arbor-ed25519-pin-v1"

      expected_pub =
        Base.decode16!(
          "2152f8d19b791d24453242e15f2eab6cb7cffa7b6a5ed30097960e069881db12",
          case: :lower
        )

      expected_sig =
        Base.decode16!(
          "afd462aa718cee97b480ac869a9d6c15f3db917023d6b73e87d5cf45cbeb90a2" <>
            "2db6d4c21de0309ce35d092e10e87fde65ce2dc400b70be4fc1dc10a797a2707",
          case: :lower
        )

      assert public_key == expected_pub
      assert Crypto.sign(message, private_key) == expected_sig
      assert Crypto.verify(message, expected_sig, public_key)
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

  describe "seal/3 and unseal/3 (ECIES — C2)" do
    # Alice is the SENDER: she signs with her Ed25519 key. Bob is the
    # RECIPIENT: he holds the X25519 keypair the message is sealed to.
    setup do
      {alice_sign_pub, alice_sign_priv} = Crypto.generate_keypair()
      {bob_enc_pub, bob_enc_priv} = Crypto.generate_encryption_keypair()

      %{
        alice_sign_pub: alice_sign_pub,
        alice_sign_priv: alice_sign_priv,
        bob_enc_pub: bob_enc_pub,
        bob_enc_priv: bob_enc_priv
      }
    end

    test "round-trip: recipient with the sender's signing pubkey decrypts", ctx do
      plaintext = "hello bob, from alice"
      sealed = Crypto.seal(plaintext, ctx.bob_enc_pub, ctx.alice_sign_priv)

      assert sealed.v == 2
      assert byte_size(sealed.ephemeral_public) == 32
      assert is_binary(sealed.signature)

      assert {:ok, ^plaintext} =
               Crypto.unseal(sealed, ctx.bob_enc_priv, ctx.alice_sign_pub)
    end

    test "forward secrecy: a fresh ephemeral key per message, not the sender's static key",
         ctx do
      s1 = Crypto.seal("same message", ctx.bob_enc_pub, ctx.alice_sign_priv)
      s2 = Crypto.seal("same message", ctx.bob_enc_pub, ctx.alice_sign_priv)

      # Distinct ephemeral keys + ciphertexts each time.
      refute s1.ephemeral_public == s2.ephemeral_public
      refute s1.ciphertext == s2.ciphertext
      # The ephemeral key is NOT the sender's signing key.
      refute s1.ephemeral_public == ctx.alice_sign_pub
    end

    test "sender authentication: a forged sender (wrong signing key) is rejected", ctx do
      {_mallory_pub, mallory_priv} = Crypto.generate_keypair()
      # Mallory seals a message but the recipient expects Alice's signature.
      sealed = Crypto.seal("trust me", ctx.bob_enc_pub, mallory_priv)

      assert {:error, :bad_signature} =
               Crypto.unseal(sealed, ctx.bob_enc_priv, ctx.alice_sign_pub)
    end

    test "tampering the ciphertext is rejected at the signature gate", ctx do
      sealed = Crypto.seal("secret", ctx.bob_enc_pub, ctx.alice_sign_priv)
      tampered = %{sealed | ciphertext: :crypto.strong_rand_bytes(byte_size(sealed.ciphertext))}

      assert {:error, :bad_signature} =
               Crypto.unseal(tampered, ctx.bob_enc_priv, ctx.alice_sign_pub)
    end

    test "wrong recipient key fails to decrypt (after a valid signature)", ctx do
      {_carol_pub, carol_priv} = Crypto.generate_encryption_keypair()
      sealed = Crypto.seal("secret", ctx.bob_enc_pub, ctx.alice_sign_priv)

      # Signature is valid (it's Alice's), but Carol's key can't derive the
      # ECDH secret → decryption fails.
      assert {:error, :decryption_failed} =
               Crypto.unseal(sealed, carol_priv, ctx.alice_sign_pub)
    end

    test "malformed sealed map is rejected", ctx do
      assert {:error, :malformed_sealed} =
               Crypto.unseal(%{garbage: true}, ctx.bob_enc_priv, ctx.alice_sign_pub)
    end

    test "security regression (H1): unseal rejects a wrong-size (Ed25519, 64-byte) recipient key",
         ctx do
      # H1: seal/unseal re-derive the ECDH from raw binaries with no type
      # distinction between X25519 (32-byte) and Ed25519 (64-byte) keys. If an
      # Ed25519 private key is mistakenly passed as the recipient key, the
      # ECDH silently produced incorrect results instead of failing. The fix
      # is a `byte_size(recipient_private) == 32` guard on unseal/3 — a 64-byte
      # key must NOT match the v2 clause; it falls through to {:error,
      # :malformed_sealed} rather than attempting a confused ECDH.
      sealed = Crypto.seal("secret", ctx.bob_enc_pub, ctx.alice_sign_priv)

      # A 64-byte key — the classic Ed25519-expanded-form confusion input that
      # the guard must reject. (Any non-32-byte recipient key must be refused.)
      ed_priv_64 = :crypto.strong_rand_bytes(64)
      assert byte_size(ed_priv_64) == 64

      assert {:error, :malformed_sealed} =
               Crypto.unseal(sealed, ed_priv_64, ctx.alice_sign_pub)
    end

    test "security regression (H1): seal rejects a wrong-size (Ed25519, 64-byte) recipient key",
         ctx do
      # The mirror of the unseal guard: seal/3 requires a 32-byte X25519
      # recipient *public* key. Passing a 64-byte Ed25519 key must raise a
      # FunctionClauseError (no matching clause) rather than silently sealing
      # to a confused/incorrect ECDH key.
      ed_pub_64 = :crypto.strong_rand_bytes(64)
      assert byte_size(ed_pub_64) == 64

      assert_raise FunctionClauseError, fn ->
        Crypto.seal("secret", ed_pub_64, ctx.alice_sign_priv)
      end
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
