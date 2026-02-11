defmodule Arbor.Behavioral.SecureCommsTest do
  @moduledoc """
  Behavioral test: secure communications handshake.

  Verifies the full encrypted communications flow:
  1. Crypto primitives (Ed25519 signing, X25519 ECDH, AES-256-GCM)
  2. Double Ratchet session establishment and message exchange
  3. Keychain peer management and sealed messaging
  4. Forward secrecy — each message uses a unique key

  Self-contained — generates fresh keypairs per test.
  """
  use Arbor.Test.BehavioralCase

  alias Arbor.Security.Crypto
  alias Arbor.Security.DoubleRatchet
  alias Arbor.Security.Keychain

  describe "scenario: cryptographic primitives" do
    test "Ed25519 sign/verify round-trip" do
      {pub, priv} = Crypto.generate_keypair()

      message = "Hello, Arbor!"
      signature = Crypto.sign(message, priv)

      assert Crypto.verify(message, signature, pub) == true
    end

    test "Ed25519 verification fails with wrong key" do
      {_pub_a, priv_a} = Crypto.generate_keypair()
      {pub_b, _priv_b} = Crypto.generate_keypair()

      message = "Signed by A"
      signature = Crypto.sign(message, priv_a)

      # B's public key should not verify A's signature
      assert Crypto.verify(message, signature, pub_b) == false
    end

    test "Ed25519 verification fails with tampered message" do
      {pub, priv} = Crypto.generate_keypair()

      signature = Crypto.sign("original", priv)
      assert Crypto.verify("tampered", signature, pub) == false
    end

    test "X25519 ECDH produces same shared secret for both parties" do
      {pub_a, priv_a} = Crypto.generate_encryption_keypair()
      {pub_b, priv_b} = Crypto.generate_encryption_keypair()

      secret_ab = Crypto.derive_shared_secret(priv_a, pub_b)
      secret_ba = Crypto.derive_shared_secret(priv_b, pub_a)

      assert secret_ab == secret_ba
      assert byte_size(secret_ab) == 32
    end

    test "AES-256-GCM encrypt/decrypt round-trip" do
      key = :crypto.strong_rand_bytes(32)
      plaintext = "Secret agent message"

      {ciphertext, iv, tag} = Crypto.encrypt(plaintext, key)

      assert {:ok, decrypted} = Crypto.decrypt(ciphertext, key, iv, tag)
      assert decrypted == plaintext
    end

    test "AES-256-GCM decryption fails with wrong key" do
      key1 = :crypto.strong_rand_bytes(32)
      key2 = :crypto.strong_rand_bytes(32)

      {ciphertext, iv, tag} = Crypto.encrypt("Secret", key1)

      assert {:error, :decryption_failed} = Crypto.decrypt(ciphertext, key2, iv, tag)
    end

    test "AES-256-GCM decryption fails with tampered ciphertext" do
      key = :crypto.strong_rand_bytes(32)

      {ciphertext, iv, tag} = Crypto.encrypt("Secret", key)
      tampered = :crypto.strong_rand_bytes(byte_size(ciphertext))

      assert {:error, :decryption_failed} = Crypto.decrypt(tampered, key, iv, tag)
    end

    test "seal/unseal provides one-shot ECDH encryption" do
      {pub_alice, priv_alice} = Crypto.generate_encryption_keypair()
      {pub_bob, priv_bob} = Crypto.generate_encryption_keypair()

      sealed = Crypto.seal("Hello Bob!", pub_bob, priv_alice)

      assert is_map(sealed)
      assert Map.has_key?(sealed, :ciphertext)
      assert Map.has_key?(sealed, :iv)
      assert Map.has_key?(sealed, :tag)
      assert Map.has_key?(sealed, :sender_public)

      assert {:ok, plaintext} = Crypto.unseal(sealed, priv_bob)
      assert plaintext == "Hello Bob!"
    end

    test "seal/unseal fails with wrong recipient key" do
      {_pub_alice, priv_alice} = Crypto.generate_encryption_keypair()
      {pub_bob, _priv_bob} = Crypto.generate_encryption_keypair()
      {_pub_eve, priv_eve} = Crypto.generate_encryption_keypair()

      sealed = Crypto.seal("Secret for Bob", pub_bob, priv_alice)

      # Eve cannot unseal Bob's message
      assert {:error, :decryption_failed} = Crypto.unseal(sealed, priv_eve)
    end

    test "derive_agent_id produces deterministic ID from public key" do
      {pub, _priv} = Crypto.generate_keypair()

      id1 = Crypto.derive_agent_id(pub)
      id2 = Crypto.derive_agent_id(pub)

      assert id1 == id2
      assert String.starts_with?(id1, "agent_")
    end
  end

  describe "scenario: Double Ratchet session" do
    setup do
      # Shared secret from X25519 ECDH (simulated)
      shared_secret = :crypto.strong_rand_bytes(32)

      # Receiver generates their DH keypair
      receiver_keypair = Crypto.generate_encryption_keypair()
      {receiver_pub, _receiver_priv} = receiver_keypair

      # Initialize sessions
      sender = DoubleRatchet.init_sender(shared_secret, receiver_pub)
      receiver = DoubleRatchet.init_receiver(shared_secret, receiver_keypair)

      {:ok, sender: sender, receiver: receiver}
    end

    test "messages encrypt and decrypt correctly", %{sender: sender, receiver: receiver} do
      # Sender encrypts
      {sender2, header, ciphertext} = DoubleRatchet.encrypt(sender, "Hello from sender!")

      assert is_map(header)
      assert Map.has_key?(header, :dh_public)
      assert is_binary(ciphertext)

      # Receiver decrypts
      assert {:ok, _receiver2, plaintext} = DoubleRatchet.decrypt(receiver, header, ciphertext)
      assert plaintext == "Hello from sender!"
    end

    test "bidirectional communication works", %{sender: sender, receiver: receiver} do
      # Sender -> Receiver
      {sender2, h1, c1} = DoubleRatchet.encrypt(sender, "Message 1")
      {:ok, receiver2, p1} = DoubleRatchet.decrypt(receiver, h1, c1)
      assert p1 == "Message 1"

      # Receiver -> Sender
      {receiver3, h2, c2} = DoubleRatchet.encrypt(receiver2, "Reply 1")
      {:ok, sender3, p2} = DoubleRatchet.decrypt(sender2, h2, c2)
      assert p2 == "Reply 1"

      # Sender -> Receiver again
      {_sender4, h3, c3} = DoubleRatchet.encrypt(sender3, "Message 2")
      {:ok, _receiver4, p3} = DoubleRatchet.decrypt(receiver3, h3, c3)
      assert p3 == "Message 2"
    end

    test "forward secrecy — each message uses different key material", %{sender: sender} do
      {sender2, header1, ciphertext1} = DoubleRatchet.encrypt(sender, "Message A")
      {_sender3, header2, ciphertext2} = DoubleRatchet.encrypt(sender2, "Message B")

      # Different ciphertexts even for same-length messages
      assert ciphertext1 != ciphertext2

      # Chain counter advances
      assert header2.n > header1.n
    end

    test "out-of-order messages handled via skipped keys", %{sender: sender, receiver: receiver} do
      # Send 3 messages
      {sender2, h1, c1} = DoubleRatchet.encrypt(sender, "First")
      {sender3, h2, c2} = DoubleRatchet.encrypt(sender2, "Second")
      {_sender4, h3, c3} = DoubleRatchet.encrypt(sender3, "Third")

      # Decrypt out of order: third, first, second
      {:ok, receiver2, p3} = DoubleRatchet.decrypt(receiver, h3, c3)
      assert p3 == "Third"

      {:ok, receiver3, p1} = DoubleRatchet.decrypt(receiver2, h1, c1)
      assert p1 == "First"

      {:ok, _receiver4, p2} = DoubleRatchet.decrypt(receiver3, h2, c2)
      assert p2 == "Second"
    end

    test "session serializes and deserializes", %{sender: sender} do
      serialized = DoubleRatchet.to_map(sender)
      assert is_map(serialized)

      {:ok, restored} = DoubleRatchet.from_map(serialized)

      # Restored session should produce valid messages
      {_restored2, _header, ciphertext} = DoubleRatchet.encrypt(restored, "After restore")
      assert is_binary(ciphertext)
    end
  end

  describe "scenario: Keychain peer messaging" do
    setup do
      alice = Keychain.new("alice_#{:erlang.unique_integer([:positive])}")
      bob = Keychain.new("bob_#{:erlang.unique_integer([:positive])}")

      # Exchange public keys (peer introduction)
      alice =
        Keychain.add_peer(
          alice,
          bob.agent_id,
          bob.signing_keypair.public,
          bob.encryption_keypair.public,
          "Bob"
        )

      bob =
        Keychain.add_peer(
          bob,
          alice.agent_id,
          alice.signing_keypair.public,
          alice.encryption_keypair.public,
          "Alice"
        )

      {:ok, alice: alice, bob: bob}
    end

    test "one-shot seal/unseal between peers", %{alice: alice, bob: bob} do
      # Alice seals for Bob (no ratchet session → falls back to one-shot ECDH)
      {:ok, sealed} = Keychain.seal_for_peer(alice, bob.agent_id, "Secret for Bob")

      assert is_map(sealed)

      # Bob unseals
      {:ok, plaintext} = Keychain.unseal_from_peer(bob, alice.agent_id, sealed)
      assert plaintext == "Secret for Bob"
    end

    test "peer management — add and get", %{alice: alice, bob: bob} do
      {:ok, peer} = Keychain.get_peer(alice, bob.agent_id)
      assert peer.name == "Bob"
      assert is_binary(peer.signing_public)
      assert is_binary(peer.encryption_public)
    end

    test "unknown peer returns error", %{alice: alice} do
      assert {:error, :unknown_peer} = Keychain.get_peer(alice, "agent_nonexistent")
    end

    test "seal_for_peer fails for unknown peer", %{alice: alice} do
      assert {:error, :unknown_peer} = Keychain.seal_for_peer(alice, "agent_unknown", "msg")
    end

    test "ratchet session establishment enables forward-secret messaging", %{alice: alice, bob: bob} do
      # Initialize ratchet sessions
      {:ok, alice} = Keychain.init_ratchet_sender(alice, bob.agent_id)
      {:ok, bob} = Keychain.init_ratchet_receiver(bob, alice.agent_id)

      assert Keychain.has_ratchet_session?(alice, bob.agent_id)
      assert Keychain.has_ratchet_session?(bob, alice.agent_id)

      # Send via ratchet (returns updated keychain)
      {:ok, sealed, alice} = Keychain.seal_for_peer(alice, bob.agent_id, "Ratcheted message")

      # Ratchet messages have a marker
      {:ok, plaintext, _bob} = Keychain.unseal_from_peer(bob, alice.agent_id, sealed)
      assert plaintext == "Ratcheted message"
    end

    test "clear_ratchet_session falls back to one-shot", %{alice: alice, bob: bob} do
      {:ok, alice} = Keychain.init_ratchet_sender(alice, bob.agent_id)
      assert Keychain.has_ratchet_session?(alice, bob.agent_id)

      alice = Keychain.clear_ratchet_session(alice, bob.agent_id)
      assert Keychain.has_ratchet_session?(alice, bob.agent_id) == false

      # Should still be able to seal via one-shot
      {:ok, _sealed} = Keychain.seal_for_peer(alice, bob.agent_id, "Back to one-shot")
    end

    test "remove_peer clears all peer state", %{alice: alice, bob: bob} do
      alice = Keychain.remove_peer(alice, bob.agent_id)

      assert {:error, :unknown_peer} = Keychain.get_peer(alice, bob.agent_id)
      assert {:error, :unknown_peer} = Keychain.seal_for_peer(alice, bob.agent_id, "msg")
    end
  end

  describe "scenario: keychain persistence" do
    test "serialize/deserialize preserves keychain state" do
      kc = Keychain.new("agent_persist_test")
      encryption_key = :crypto.strong_rand_bytes(32)

      {:ok, serialized} = Keychain.serialize(kc, encryption_key)
      assert is_binary(serialized)

      {:ok, restored} = Keychain.deserialize(serialized, encryption_key)
      assert restored.agent_id == kc.agent_id
      assert restored.signing_keypair.public == kc.signing_keypair.public
      assert restored.encryption_keypair.public == kc.encryption_keypair.public
    end

    test "deserialize fails with wrong encryption key" do
      kc = Keychain.new("agent_wrong_key_test")
      key1 = :crypto.strong_rand_bytes(32)
      key2 = :crypto.strong_rand_bytes(32)

      {:ok, serialized} = Keychain.serialize(kc, key1)

      assert {:error, _} = Keychain.deserialize(serialized, key2)
    end

    test "escrow provides disaster recovery" do
      kc = Keychain.new("agent_escrow_test")
      agent_key = :crypto.strong_rand_bytes(32)
      escrow_key = :crypto.strong_rand_bytes(32)

      {:ok, escrowed} = Keychain.create_escrow(kc, agent_key, escrow_key)
      assert is_binary(escrowed)

      {:ok, recovered} = Keychain.recover_from_escrow(escrowed, escrow_key, agent_key)
      assert recovered.agent_id == kc.agent_id
    end
  end
end
