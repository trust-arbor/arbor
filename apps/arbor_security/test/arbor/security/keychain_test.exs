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
end
