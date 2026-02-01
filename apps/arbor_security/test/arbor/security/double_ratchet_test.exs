defmodule Arbor.Security.DoubleRatchetTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Security.Crypto
  alias Arbor.Security.DoubleRatchet

  describe "session initialization" do
    test "init_sender creates a valid session" do
      shared_secret = :crypto.strong_rand_bytes(32)
      {remote_pub, _remote_priv} = Crypto.generate_encryption_keypair()

      session = DoubleRatchet.init_sender(shared_secret, remote_pub)

      assert %DoubleRatchet{} = session
      assert session.dh_remote == remote_pub
      assert is_binary(elem(session.dh_keypair, 0))
      assert is_binary(session.root_key)
      assert is_binary(session.send_chain.key)
      assert session.send_chain.n == 0
    end

    test "init_receiver creates a valid session" do
      shared_secret = :crypto.strong_rand_bytes(32)
      my_keypair = Crypto.generate_encryption_keypair()

      session = DoubleRatchet.init_receiver(shared_secret, my_keypair)

      assert %DoubleRatchet{} = session
      assert is_nil(session.dh_remote)
      assert session.dh_keypair == my_keypair
      assert session.root_key == shared_secret
      assert is_nil(session.send_chain.key)
    end

    test "max_skip option is respected" do
      shared_secret = :crypto.strong_rand_bytes(32)
      {remote_pub, _remote_priv} = Crypto.generate_encryption_keypair()

      session = DoubleRatchet.init_sender(shared_secret, remote_pub, max_skip: 50)

      assert session.max_skip == 50
    end
  end

  describe "encrypt/decrypt round-trip" do
    setup do
      # Establish shared secret via ECDH (simulating key exchange)
      alice_keypair = Crypto.generate_encryption_keypair()
      bob_keypair = Crypto.generate_encryption_keypair()
      {alice_pub, alice_priv} = alice_keypair
      {bob_pub, bob_priv} = bob_keypair

      # Both parties derive the same shared secret
      alice_secret = Crypto.derive_shared_secret(alice_priv, bob_pub)
      bob_secret = Crypto.derive_shared_secret(bob_priv, alice_pub)
      assert alice_secret == bob_secret

      %{
        shared_secret: alice_secret,
        alice_keypair: alice_keypair,
        bob_keypair: bob_keypair,
        bob_pub: bob_pub
      }
    end

    test "basic message round-trip works", %{shared_secret: secret, bob_keypair: bob_kp, bob_pub: bob_pub} do
      # Alice is sender, Bob is receiver
      alice = DoubleRatchet.init_sender(secret, bob_pub)
      bob = DoubleRatchet.init_receiver(secret, bob_kp)

      # Alice encrypts
      plaintext = "Hello, Bob!"
      {alice2, header, ciphertext} = DoubleRatchet.encrypt(alice, plaintext)

      # Bob decrypts
      {:ok, bob2, decrypted} = DoubleRatchet.decrypt(bob, header, ciphertext)

      assert decrypted == plaintext
      assert alice2.send_chain.n == 1
      assert bob2.recv_chain.n == 1
    end

    test "multiple messages maintain session state", %{shared_secret: secret, bob_keypair: bob_kp, bob_pub: bob_pub} do
      alice = DoubleRatchet.init_sender(secret, bob_pub)
      bob = DoubleRatchet.init_receiver(secret, bob_kp)

      messages = ["Message 1", "Message 2", "Message 3"]

      {final_alice, final_bob, decrypted_messages} =
        Enum.reduce(messages, {alice, bob, []}, fn msg, {a, b, acc} ->
          {a2, header, ct} = DoubleRatchet.encrypt(a, msg)
          {:ok, b2, pt} = DoubleRatchet.decrypt(b, header, ct)
          {a2, b2, acc ++ [pt]}
        end)

      assert decrypted_messages == messages
      assert final_alice.send_chain.n == 3
      assert final_bob.recv_chain.n == 3
    end

    test "bidirectional communication works", %{shared_secret: secret, alice_keypair: alice_kp, bob_keypair: bob_kp, bob_pub: bob_pub} do
      {alice_pub, _} = alice_kp

      # Alice sends first
      alice = DoubleRatchet.init_sender(secret, bob_pub)
      bob = DoubleRatchet.init_receiver(secret, bob_kp)

      # Alice -> Bob
      {alice2, h1, c1} = DoubleRatchet.encrypt(alice, "Hello from Alice")
      {:ok, bob2, m1} = DoubleRatchet.decrypt(bob, h1, c1)
      assert m1 == "Hello from Alice"

      # Bob -> Alice (Bob needs to know Alice's DH public key from header)
      # After receiving, Bob can send using Alice's public key from the header
      # The DH ratchet advances when Bob sends
      {bob3, h2, c2} = DoubleRatchet.encrypt(bob2, "Hello from Bob")
      {:ok, alice3, m2} = DoubleRatchet.decrypt(alice2, h2, c2)
      assert m2 == "Hello from Bob"

      # Alice -> Bob again
      {alice4, h3, c3} = DoubleRatchet.encrypt(alice3, "Another message")
      {:ok, bob4, m3} = DoubleRatchet.decrypt(bob3, h3, c3)
      assert m3 == "Another message"
    end
  end

  describe "forward secrecy" do
    test "per-message keys differ", %{} do
      shared_secret = :crypto.strong_rand_bytes(32)
      {bob_pub, _} = Crypto.generate_encryption_keypair()

      alice = DoubleRatchet.init_sender(shared_secret, bob_pub)

      # Encrypt two messages with the same plaintext
      {alice2, header1, ciphertext1} = DoubleRatchet.encrypt(alice, "same message")
      {_alice3, header2, ciphertext2} = DoubleRatchet.encrypt(alice2, "same message")

      # Ciphertexts should be different (different IVs and message keys)
      assert ciphertext1 != ciphertext2

      # Message counters should increment
      assert header1.n == 0
      assert header2.n == 1
    end

    test "DH ratchet advances on new remote public key" do
      shared_secret = :crypto.strong_rand_bytes(32)
      alice_keypair = Crypto.generate_encryption_keypair()
      bob_keypair = Crypto.generate_encryption_keypair()
      {_alice_pub, _alice_priv} = alice_keypair
      {bob_pub, _bob_priv} = bob_keypair

      alice = DoubleRatchet.init_sender(shared_secret, bob_pub)
      bob = DoubleRatchet.init_receiver(shared_secret, bob_keypair)

      # Alice sends
      {alice2, h1, c1} = DoubleRatchet.encrypt(alice, "First")
      {:ok, bob2, _} = DoubleRatchet.decrypt(bob, h1, c1)

      # Bob sends back (this triggers DH ratchet on Alice's side)
      {bob3, h2, c2} = DoubleRatchet.encrypt(bob2, "Reply")

      # Alice receives Bob's message - should trigger DH ratchet
      initial_root_key = alice2.root_key
      {:ok, alice3, _} = DoubleRatchet.decrypt(alice2, h2, c2)

      # Root key should have changed due to DH ratchet
      assert alice3.root_key != initial_root_key
      assert alice3.dh_remote == h2.dh_public
    end
  end

  describe "out-of-order messages" do
    test "skipped messages decrypt via skipped keys" do
      shared_secret = :crypto.strong_rand_bytes(32)
      bob_keypair = Crypto.generate_encryption_keypair()
      {bob_pub, _} = bob_keypair

      alice = DoubleRatchet.init_sender(shared_secret, bob_pub)
      bob = DoubleRatchet.init_receiver(shared_secret, bob_keypair)

      # Alice sends three messages
      {alice2, h1, c1} = DoubleRatchet.encrypt(alice, "Message 1")
      {alice3, h2, c2} = DoubleRatchet.encrypt(alice2, "Message 2")
      {_alice4, h3, c3} = DoubleRatchet.encrypt(alice3, "Message 3")

      # Bob receives message 3 first (skipping 1 and 2)
      {:ok, bob2, m3} = DoubleRatchet.decrypt(bob, h3, c3)
      assert m3 == "Message 3"

      # Skipped keys should be stored
      assert map_size(bob2.skipped_keys) == 2

      # Bob can now decrypt message 1 out of order
      {:ok, bob3, m1} = DoubleRatchet.decrypt(bob2, h1, c1)
      assert m1 == "Message 1"
      assert map_size(bob3.skipped_keys) == 1

      # And message 2
      {:ok, bob4, m2} = DoubleRatchet.decrypt(bob3, h2, c2)
      assert m2 == "Message 2"
      assert map_size(bob4.skipped_keys) == 0
    end

    test "max_skip exceeded returns error" do
      shared_secret = :crypto.strong_rand_bytes(32)
      bob_keypair = Crypto.generate_encryption_keypair()
      {bob_pub, _} = bob_keypair

      alice = DoubleRatchet.init_sender(shared_secret, bob_pub, max_skip: 3)
      bob = DoubleRatchet.init_receiver(shared_secret, bob_keypair, max_skip: 3)

      # Alice sends 5 messages
      {alice2, _h1, _c1} = DoubleRatchet.encrypt(alice, "1")
      {alice3, _h2, _c2} = DoubleRatchet.encrypt(alice2, "2")
      {alice4, _h3, _c3} = DoubleRatchet.encrypt(alice3, "3")
      {alice5, _h4, _c4} = DoubleRatchet.encrypt(alice4, "4")
      {_alice6, h5, c5} = DoubleRatchet.encrypt(alice5, "5")

      # Bob tries to receive message 5 first (skipping 4 messages, but max_skip is 3)
      result = DoubleRatchet.decrypt(bob, h5, c5)

      assert {:error, :max_skip_exceeded} = result
    end
  end

  describe "serialization" do
    test "to_map/from_map round-trip preserves session" do
      shared_secret = :crypto.strong_rand_bytes(32)
      {bob_pub, _} = Crypto.generate_encryption_keypair()

      session = DoubleRatchet.init_sender(shared_secret, bob_pub)

      # Encrypt a few messages to advance state
      {session2, _h1, _c1} = DoubleRatchet.encrypt(session, "msg1")
      {session3, _h2, _c2} = DoubleRatchet.encrypt(session2, "msg2")

      # Serialize and deserialize
      session_map = DoubleRatchet.to_map(session3)
      {:ok, restored} = DoubleRatchet.from_map(session_map)

      # Verify key fields match
      assert restored.dh_keypair == session3.dh_keypair
      assert restored.dh_remote == session3.dh_remote
      assert restored.root_key == session3.root_key
      assert restored.send_chain.key == session3.send_chain.key
      assert restored.send_chain.n == session3.send_chain.n
      assert restored.max_skip == session3.max_skip
    end

    test "serialized session can continue encrypting" do
      shared_secret = :crypto.strong_rand_bytes(32)
      bob_keypair = Crypto.generate_encryption_keypair()
      {bob_pub, _} = bob_keypair

      alice = DoubleRatchet.init_sender(shared_secret, bob_pub)
      bob = DoubleRatchet.init_receiver(shared_secret, bob_keypair)

      # Alice encrypts, serialize, deserialize
      {alice2, h1, c1} = DoubleRatchet.encrypt(alice, "before serialize")
      {:ok, bob2, m1} = DoubleRatchet.decrypt(bob, h1, c1)
      assert m1 == "before serialize"

      # Serialize and restore Alice's session
      alice_map = DoubleRatchet.to_map(alice2)
      {:ok, alice_restored} = DoubleRatchet.from_map(alice_map)

      # Continue encrypting with restored session
      {_alice3, h2, c2} = DoubleRatchet.encrypt(alice_restored, "after serialize")
      {:ok, _bob3, m2} = DoubleRatchet.decrypt(bob2, h2, c2)
      assert m2 == "after serialize"
    end
  end

  describe "additional authenticated data (AAD)" do
    test "AAD is validated during decryption" do
      shared_secret = :crypto.strong_rand_bytes(32)
      bob_keypair = Crypto.generate_encryption_keypair()
      {bob_pub, _} = bob_keypair

      alice = DoubleRatchet.init_sender(shared_secret, bob_pub)
      bob = DoubleRatchet.init_receiver(shared_secret, bob_keypair)

      # Alice encrypts with AAD
      {_alice2, header, ciphertext} = DoubleRatchet.encrypt(alice, "secret", "channel:123")

      # Bob tries to decrypt with different AAD
      result = DoubleRatchet.decrypt(bob, header, ciphertext, "channel:456")

      assert {:error, :decryption_failed} = result
    end

    test "matching AAD allows decryption" do
      shared_secret = :crypto.strong_rand_bytes(32)
      bob_keypair = Crypto.generate_encryption_keypair()
      {bob_pub, _} = bob_keypair

      alice = DoubleRatchet.init_sender(shared_secret, bob_pub)
      bob = DoubleRatchet.init_receiver(shared_secret, bob_keypair)

      aad = "channel:123"
      {_alice2, header, ciphertext} = DoubleRatchet.encrypt(alice, "secret", aad)
      {:ok, _bob2, plaintext} = DoubleRatchet.decrypt(bob, header, ciphertext, aad)

      assert plaintext == "secret"
    end
  end

  describe "error handling" do
    test "tampered ciphertext fails decryption" do
      shared_secret = :crypto.strong_rand_bytes(32)
      bob_keypair = Crypto.generate_encryption_keypair()
      {bob_pub, _} = bob_keypair

      alice = DoubleRatchet.init_sender(shared_secret, bob_pub)
      bob = DoubleRatchet.init_receiver(shared_secret, bob_keypair)

      {_alice2, header, ciphertext} = DoubleRatchet.encrypt(alice, "secret message")

      # Tamper with ciphertext by flipping bits
      <<first_byte::8, rest::binary>> = ciphertext
      tampered = <<Bitwise.bxor(first_byte, 0xFF)::8, rest::binary>>

      result = DoubleRatchet.decrypt(bob, header, tampered)

      assert {:error, :decryption_failed} = result
    end

    test "wrong receiver session fails decryption" do
      shared_secret = :crypto.strong_rand_bytes(32)
      {bob_pub, _} = Crypto.generate_encryption_keypair()

      alice = DoubleRatchet.init_sender(shared_secret, bob_pub)

      # Different receiver with different keypair
      wrong_keypair = Crypto.generate_encryption_keypair()
      wrong_bob = DoubleRatchet.init_receiver(shared_secret, wrong_keypair)

      {_alice2, header, ciphertext} = DoubleRatchet.encrypt(alice, "secret")

      result = DoubleRatchet.decrypt(wrong_bob, header, ciphertext)

      assert {:error, :decryption_failed} = result
    end
  end
end
