defmodule Arbor.Security.KeychainTest do
  use ExUnit.Case, async: true

  alias Arbor.Security.Keychain

  @moduletag :fast

  describe "new/1" do
    test "creates keychain with fresh keypairs" do
      kc = Keychain.new("agent_test")

      assert kc.agent_id == "agent_test"
      assert byte_size(kc.signing_keypair.public) == 32
      assert byte_size(kc.signing_keypair.private) == 32
      assert byte_size(kc.encryption_keypair.public) == 32
      assert byte_size(kc.encryption_keypair.private) == 32
      assert kc.peers == %{}
      assert kc.channel_keys == %{}
    end
  end

  describe "from_keypairs/3" do
    test "creates keychain from existing keypairs" do
      {sign_pub, sign_priv} = :crypto.generate_key(:eddsa, :ed25519)
      {enc_pub, enc_priv} = :crypto.generate_key(:ecdh, :x25519)

      kc = Keychain.from_keypairs("agent_x", {sign_pub, sign_priv}, {enc_pub, enc_priv})

      assert kc.signing_keypair.public == sign_pub
      assert kc.encryption_keypair.private == enc_priv
    end
  end

  describe "peer management" do
    setup do
      kc = Keychain.new("agent_alice")
      {bob_sign_pub, _} = :crypto.generate_key(:eddsa, :ed25519)
      {bob_enc_pub, _} = :crypto.generate_key(:ecdh, :x25519)
      {:ok, kc: kc, bob_sign_pub: bob_sign_pub, bob_enc_pub: bob_enc_pub}
    end

    test "add_peer stores peer keys", ctx do
      kc = Keychain.add_peer(ctx.kc, "agent_bob", ctx.bob_sign_pub, ctx.bob_enc_pub, "bob")

      assert {:ok, peer} = Keychain.get_peer(kc, "agent_bob")
      assert peer.signing_public == ctx.bob_sign_pub
      assert peer.encryption_public == ctx.bob_enc_pub
      assert peer.name == "bob"
      assert %DateTime{} = peer.trusted_at
    end

    test "get_peer returns error for unknown peer", ctx do
      assert {:error, :unknown_peer} = Keychain.get_peer(ctx.kc, "agent_unknown")
    end

    test "remove_peer deletes the peer", ctx do
      kc =
        ctx.kc
        |> Keychain.add_peer("agent_bob", ctx.bob_sign_pub, ctx.bob_enc_pub, "bob")
        |> Keychain.remove_peer("agent_bob")

      assert {:error, :unknown_peer} = Keychain.get_peer(kc, "agent_bob")
    end

    test "add_peer with nil name" do
      kc = Keychain.new("agent_a")
      {sign_pub, _} = :crypto.generate_key(:eddsa, :ed25519)
      {enc_pub, _} = :crypto.generate_key(:ecdh, :x25519)

      kc = Keychain.add_peer(kc, "agent_b", sign_pub, enc_pub)

      assert {:ok, peer} = Keychain.get_peer(kc, "agent_b")
      assert peer.name == nil
    end
  end

  describe "channel key management" do
    test "store and retrieve channel key" do
      kc = Keychain.new("agent_a")
      key = :crypto.strong_rand_bytes(32)

      kc = Keychain.store_channel_key(kc, "channel_123", key)

      assert {:ok, ^key} = Keychain.get_channel_key(kc, "channel_123")
    end

    test "unknown channel returns error" do
      kc = Keychain.new("agent_a")
      assert {:error, :unknown_channel} = Keychain.get_channel_key(kc, "nope")
    end

    test "remove_channel_key" do
      kc = Keychain.new("agent_a")
      key = :crypto.strong_rand_bytes(32)

      kc =
        kc
        |> Keychain.store_channel_key("ch1", key)
        |> Keychain.remove_channel_key("ch1")

      assert {:error, :unknown_channel} = Keychain.get_channel_key(kc, "ch1")
    end
  end

  describe "sealed communication" do
    setup do
      alice = Keychain.new("agent_alice")
      bob = Keychain.new("agent_bob")

      # Each adds the other as a peer
      alice =
        Keychain.add_peer(
          alice,
          "agent_bob",
          bob.signing_keypair.public,
          bob.encryption_keypair.public,
          "bob"
        )

      bob =
        Keychain.add_peer(
          bob,
          "agent_alice",
          alice.signing_keypair.public,
          alice.encryption_keypair.public,
          "alice"
        )

      {:ok, alice: alice, bob: bob}
    end

    test "seal_for_peer and unseal_from_peer round-trip", %{alice: alice, bob: bob} do
      plaintext = "classified intel from alice"

      assert {:ok, sealed} = Keychain.seal_for_peer(alice, "agent_bob", plaintext)
      assert {:ok, ^plaintext} = Keychain.unseal_from_peer(bob, "agent_alice", sealed)
    end

    test "seal_for_peer fails for unknown peer", %{alice: alice} do
      assert {:error, :unknown_peer} = Keychain.seal_for_peer(alice, "agent_unknown", "data")
    end

    test "unseal_from_peer fails for unknown sender", %{bob: bob} do
      fake_sealed = %{ciphertext: "x", iv: "y", tag: "z", sender_public: "w"}

      assert {:error, :unknown_peer} =
               Keychain.unseal_from_peer(bob, "agent_unknown", fake_sealed)
    end

    test "bidirectional communication", %{alice: alice, bob: bob} do
      # Alice -> Bob
      {:ok, sealed_ab} = Keychain.seal_for_peer(alice, "agent_bob", "hello bob")
      assert {:ok, "hello bob"} = Keychain.unseal_from_peer(bob, "agent_alice", sealed_ab)

      # Bob -> Alice
      {:ok, sealed_ba} = Keychain.seal_for_peer(bob, "agent_alice", "hello alice")
      assert {:ok, "hello alice"} = Keychain.unseal_from_peer(alice, "agent_bob", sealed_ba)
    end
  end

  describe "Double Ratchet integration" do
    setup do
      alice = Keychain.new("agent_alice")
      bob = Keychain.new("agent_bob")

      alice =
        Keychain.add_peer(
          alice,
          "agent_bob",
          bob.signing_keypair.public,
          bob.encryption_keypair.public,
          "bob"
        )

      bob =
        Keychain.add_peer(
          bob,
          "agent_alice",
          alice.signing_keypair.public,
          alice.encryption_keypair.public,
          "alice"
        )

      {:ok, alice: alice, bob: bob}
    end

    test "init_ratchet_sender creates session", %{alice: alice} do
      refute Keychain.has_ratchet_session?(alice, "agent_bob")

      {:ok, alice2} = Keychain.init_ratchet_sender(alice, "agent_bob")

      assert Keychain.has_ratchet_session?(alice2, "agent_bob")
    end

    test "init_ratchet_receiver creates session", %{bob: bob} do
      {:ok, bob2} = Keychain.init_ratchet_receiver(bob, "agent_alice")

      assert Keychain.has_ratchet_session?(bob2, "agent_alice")
    end

    test "ratchet session used for seal_for_peer when present", %{alice: alice, bob: bob} do
      # Initialize ratchet sessions
      {:ok, alice2} = Keychain.init_ratchet_sender(alice, "agent_bob")
      {:ok, bob2} = Keychain.init_ratchet_receiver(bob, "agent_alice")

      # Seal with ratchet - returns 3-tuple with updated keychain
      {:ok, sealed, alice3} = Keychain.seal_for_peer(alice2, "agent_bob", "ratchet message")

      # Should be a ratchet message
      assert sealed.__ratchet__ == true
      assert is_map(sealed.header)
      assert is_binary(sealed.ciphertext)

      # Unseal with ratchet - returns 3-tuple with updated keychain
      {:ok, plaintext, _bob3} = Keychain.unseal_from_peer(bob2, "agent_alice", sealed)
      assert plaintext == "ratchet message"

      # Verify session state advanced
      {:ok, peer} = Keychain.get_peer(alice3, "agent_bob")
      assert peer.ratchet_session.send_chain.n == 1
    end

    test "falls back to ECDH when no ratchet session", %{alice: alice, bob: bob} do
      # No ratchet initialized - should use one-shot ECDH
      {:ok, sealed} = Keychain.seal_for_peer(alice, "agent_bob", "ecdh message")

      # Should NOT be a ratchet message
      refute Map.has_key?(sealed, :__ratchet__)

      {:ok, plaintext} = Keychain.unseal_from_peer(bob, "agent_alice", sealed)
      assert plaintext == "ecdh message"
    end

    test "clear_ratchet_session removes session", %{alice: alice} do
      {:ok, alice2} = Keychain.init_ratchet_sender(alice, "agent_bob")
      assert Keychain.has_ratchet_session?(alice2, "agent_bob")

      alice3 = Keychain.clear_ratchet_session(alice2, "agent_bob")
      refute Keychain.has_ratchet_session?(alice3, "agent_bob")
    end

    test "init_ratchet_sender fails for unknown peer" do
      kc = Keychain.new("agent_test")
      assert {:error, :unknown_peer} = Keychain.init_ratchet_sender(kc, "agent_unknown")
    end
  end

  describe "serialization" do
    test "serialize/deserialize round-trip preserves keychain" do
      kc = Keychain.new("agent_test")
      encryption_key = :crypto.strong_rand_bytes(32)

      {:ok, serialized} = Keychain.serialize(kc, encryption_key)
      assert is_binary(serialized)

      {:ok, restored} = Keychain.deserialize(serialized, encryption_key)

      assert restored.agent_id == kc.agent_id
      assert restored.signing_keypair.public == kc.signing_keypair.public
      assert restored.signing_keypair.private == kc.signing_keypair.private
      assert restored.encryption_keypair.public == kc.encryption_keypair.public
      assert restored.encryption_keypair.private == kc.encryption_keypair.private
    end

    test "serialization preserves peers" do
      kc = Keychain.new("agent_alice")
      {bob_sign_pub, _} = :crypto.generate_key(:eddsa, :ed25519)
      {bob_enc_pub, _} = :crypto.generate_key(:ecdh, :x25519)

      kc = Keychain.add_peer(kc, "agent_bob", bob_sign_pub, bob_enc_pub, "bob")
      encryption_key = :crypto.strong_rand_bytes(32)

      {:ok, serialized} = Keychain.serialize(kc, encryption_key)
      {:ok, restored} = Keychain.deserialize(serialized, encryption_key)

      {:ok, peer} = Keychain.get_peer(restored, "agent_bob")
      assert peer.signing_public == bob_sign_pub
      assert peer.encryption_public == bob_enc_pub
      assert peer.name == "bob"
    end

    test "serialization preserves channel keys" do
      kc = Keychain.new("agent_test")
      channel_key = :crypto.strong_rand_bytes(32)
      kc = Keychain.store_channel_key(kc, "channel_123", channel_key)
      encryption_key = :crypto.strong_rand_bytes(32)

      {:ok, serialized} = Keychain.serialize(kc, encryption_key)
      {:ok, restored} = Keychain.deserialize(serialized, encryption_key)

      {:ok, restored_key} = Keychain.get_channel_key(restored, "channel_123")
      assert restored_key == channel_key
    end

    test "private keys are encrypted in serialized payload" do
      kc = Keychain.new("agent_test")
      encryption_key = :crypto.strong_rand_bytes(32)

      {:ok, serialized} = Keychain.serialize(kc, encryption_key)
      {:ok, payload} = Jason.decode(serialized)

      # Private key should be in encrypted section, not visible in public section
      refute Map.has_key?(payload["public"], "signing_private")
      refute Map.has_key?(payload["public"], "encryption_private")

      # Encrypted private section should exist
      assert is_binary(payload["private_encrypted"])
      assert is_binary(payload["iv"])
      assert is_binary(payload["tag"])
    end

    test "wrong encryption key fails deserialization" do
      kc = Keychain.new("agent_test")
      encryption_key = :crypto.strong_rand_bytes(32)
      wrong_key = :crypto.strong_rand_bytes(32)

      {:ok, serialized} = Keychain.serialize(kc, encryption_key)
      result = Keychain.deserialize(serialized, wrong_key)

      assert {:error, :invalid_encryption_key} = result
    end

    test "tampered encrypted payload fails deserialization" do
      kc = Keychain.new("agent_test")
      encryption_key = :crypto.strong_rand_bytes(32)

      {:ok, serialized} = Keychain.serialize(kc, encryption_key)
      {:ok, data} = Jason.decode(serialized)

      # Tamper with the encrypted private data
      original_encrypted = data["private_encrypted"]
      {:ok, decoded} = Base.decode64(original_encrypted)
      <<first_byte::8, rest::binary>> = decoded
      tampered_bytes = <<Bitwise.bxor(first_byte, 0xFF)::8, rest::binary>>
      tampered_encrypted = Base.encode64(tampered_bytes)

      tampered_data = %{data | "private_encrypted" => tampered_encrypted}
      tampered = Jason.encode!(tampered_data)

      result = Keychain.deserialize(tampered, encryption_key)

      # Should fail due to decryption failure (tampered ciphertext)
      assert {:error, :invalid_encryption_key} = result
    end

    test "different agents get different encryption results" do
      kc1 = Keychain.new("agent_1")
      kc2 = Keychain.new("agent_2")
      encryption_key = :crypto.strong_rand_bytes(32)

      {:ok, serialized1} = Keychain.serialize(kc1, encryption_key)
      {:ok, serialized2} = Keychain.serialize(kc2, encryption_key)

      # Different keychains produce different serializations
      assert serialized1 != serialized2
    end

    test "Double Ratchet session state survives serialization" do
      alice = Keychain.new("agent_alice")
      bob = Keychain.new("agent_bob")

      alice =
        Keychain.add_peer(
          alice,
          "agent_bob",
          bob.signing_keypair.public,
          bob.encryption_keypair.public,
          "bob"
        )

      {:ok, alice2} = Keychain.init_ratchet_sender(alice, "agent_bob")

      # Encrypt a message to advance the ratchet state
      {:ok, _sealed, alice3} = Keychain.seal_for_peer(alice2, "agent_bob", "test message")

      encryption_key = :crypto.strong_rand_bytes(32)
      {:ok, serialized} = Keychain.serialize(alice3, encryption_key)
      {:ok, restored} = Keychain.deserialize(serialized, encryption_key)

      # Verify ratchet session was restored
      assert Keychain.has_ratchet_session?(restored, "agent_bob")

      {:ok, peer} = Keychain.get_peer(restored, "agent_bob")
      assert peer.ratchet_session.send_chain.n == 1
    end
  end

  describe "escrow" do
    test "create_escrow and recover_from_escrow round-trip" do
      kc = Keychain.new("agent_test")
      agent_key = :crypto.strong_rand_bytes(32)
      escrow_key = :crypto.strong_rand_bytes(32)

      {:ok, escrowed} = Keychain.create_escrow(kc, agent_key, escrow_key)
      assert is_binary(escrowed)

      {:ok, recovered} = Keychain.recover_from_escrow(escrowed, escrow_key, agent_key)

      assert recovered.agent_id == kc.agent_id
      assert recovered.signing_keypair.private == kc.signing_keypair.private
    end

    test "wrong escrow key fails recovery" do
      kc = Keychain.new("agent_test")
      agent_key = :crypto.strong_rand_bytes(32)
      escrow_key = :crypto.strong_rand_bytes(32)
      wrong_escrow_key = :crypto.strong_rand_bytes(32)

      {:ok, escrowed} = Keychain.create_escrow(kc, agent_key, escrow_key)
      result = Keychain.recover_from_escrow(escrowed, wrong_escrow_key, agent_key)

      assert {:error, :invalid_escrow_key} = result
    end

    test "wrong agent key fails recovery" do
      kc = Keychain.new("agent_test")
      agent_key = :crypto.strong_rand_bytes(32)
      escrow_key = :crypto.strong_rand_bytes(32)
      wrong_agent_key = :crypto.strong_rand_bytes(32)

      {:ok, escrowed} = Keychain.create_escrow(kc, agent_key, escrow_key)
      result = Keychain.recover_from_escrow(escrowed, escrow_key, wrong_agent_key)

      assert {:error, :invalid_encryption_key} = result
    end
  end
end
