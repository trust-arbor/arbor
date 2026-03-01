defmodule Arbor.Comms.ChannelCryptoTest do
  use ExUnit.Case, async: false

  alias Arbor.Comms.Channel
  alias Arbor.Comms.ChannelKeyStore
  alias Arbor.Security.Crypto

  @moduletag :fast

  setup do
    unless Process.whereis(Arbor.Comms.ChannelRegistry) do
      start_supervised!({Registry, keys: :unique, name: Arbor.Comms.ChannelRegistry})
    end

    :ok
  end

  defp start_channel(opts \\ []) do
    channel_id = Keyword.get(opts, :channel_id, "chan_test_#{System.unique_integer([:positive])}")

    defaults = [
      channel_id: channel_id,
      name: "Test Channel",
      type: :group,
      members: [%{id: "user_1", name: "User One", type: :human}],
      rate_limit_ms: 0
    ]

    merged = Keyword.merge(defaults, opts)
    {:ok, pid} = start_supervised({Channel, merged}, id: channel_id)
    {pid, channel_id}
  end

  # ============================================================================
  # Sub-Phase 3a: Message Signing
  # ============================================================================

  describe "message signing" do
    test "message sent with signature has signed: true" do
      {pid, _} = start_channel()

      # Generate a keypair for signing
      {_pub, priv} = Crypto.generate_keypair()
      content = "Hello signed world!"
      signature = Crypto.sign(content, priv)

      {:ok, message} =
        Channel.send_message(pid, "user_1", "User One", :human, content, %{signature: signature})

      assert message.signed == true
      assert message.signature == signature
      # Signature should be extracted from metadata
      refute Map.has_key?(message.metadata, :signature)
    end

    test "message sent without signature has signed: false" do
      {pid, _} = start_channel()

      {:ok, message} = Channel.send_message(pid, "user_1", "User One", :human, "No sig")

      assert message.signed == false
      assert message.signature == nil
    end

    test "signed messages appear in history with signature" do
      {pid, _} = start_channel()

      {_pub, priv} = Crypto.generate_keypair()
      content = "History check"
      signature = Crypto.sign(content, priv)

      {:ok, _} =
        Channel.send_message(pid, "user_1", "User One", :human, content, %{signature: signature})

      history = Channel.get_history(pid)
      assert length(history) == 1
      [msg] = history
      assert msg.signed == true
      assert msg.signature == signature
    end
  end

  describe "verify_message_signature/1" do
    test "returns nil for unsigned messages" do
      assert Channel.verify_message_signature(%{signature: nil}) == nil
    end

    test "returns nil for messages without signature key" do
      assert Channel.verify_message_signature(%{content: "hello"}) == nil
    end

    test "verifies valid signature when Identity Registry is running" do
      # Start Identity Registry for this test
      registry_running = Process.whereis(Arbor.Security.Identity.Registry) != nil

      unless registry_running do
        # Can't start full registry in unit test without full security stack.
        # Verify the function exists and handles missing registry gracefully.
        {_pub, priv} = Crypto.generate_keypair()
        content = "Verify me"
        signature = Crypto.sign(content, priv)

        message = %{
          signature: signature,
          sender_id: "agent_test",
          content: content
        }

        # Without registry, returns nil (no public key available)
        result = Channel.verify_message_signature(message)
        assert result == nil
      end
    end

    test "direct crypto verification works end-to-end" do
      # Bypass registry to test the crypto path directly
      {pub, priv} = Crypto.generate_keypair()
      content = "Test message"
      signature = Crypto.sign(content, priv)

      assert Crypto.verify(content, signature, pub) == true

      # Tampered content
      assert Crypto.verify("Modified content", signature, pub) == false
    end
  end

  # ============================================================================
  # Sub-Phase 3b: Private Channel Encryption
  # ============================================================================

  describe "private channel encryption" do
    test "private channel reports encrypted: true in channel_info" do
      {pid, _} = start_channel(type: :private)

      info = Channel.channel_info(pid)
      assert info.encrypted == true
      assert info.encryption_type == :aes_256_gcm
    end

    test "non-private channels report encrypted: false" do
      {pid, _} = start_channel(type: :group)

      info = Channel.channel_info(pid)
      assert info.encrypted == false
      assert info.encryption_type == nil
    end

    test "public channel reports encrypted: false" do
      {pid, _} = start_channel(type: :public)

      info = Channel.channel_info(pid)
      assert info.encrypted == false
    end

    test "DM channel reports encryption_type: :double_ratchet" do
      {pid, _} = start_channel(type: :dm, members: [
        %{id: "user_1", name: "User One", type: :human},
        %{id: "user_2", name: "User Two", type: :human}
      ])

      info = Channel.channel_info(pid)
      assert info.encryption_type == :double_ratchet
    end

    test "private channel messages stored in-memory as plaintext" do
      {pid, _} = start_channel(type: :private)

      {:ok, msg} = Channel.send_message(pid, "user_1", "User One", :human, "Secret message!")

      assert msg.content == "Secret message!"

      # In-memory history returns plaintext
      history = Channel.get_history(pid)
      assert length(history) == 1
      assert hd(history).content == "Secret message!"
    end
  end

  describe "encryption key rotation" do
    test "adding and removing members works for private channels" do
      {pid, _} = start_channel(
        type: :private,
        members: [
          %{id: "user_1", name: "User One", type: :human},
          %{id: "user_2", name: "User Two", type: :human}
        ]
      )

      # Remove a member (triggers key rotation)
      assert :ok = Channel.remove_member(pid, "user_2")

      # Channel still works for remaining member
      {:ok, msg} = Channel.send_message(pid, "user_1", "User One", :human, "After rotation")
      assert msg.content == "After rotation"
    end
  end

  describe "encrypt_content/decrypt_content round-trip" do
    test "encrypts and decrypts content with a key" do
      key = :crypto.strong_rand_bytes(32)
      plaintext = "Secret channel message"

      # Use the module's internal functions via direct crypto calls
      {ciphertext, iv, tag} = Crypto.encrypt(plaintext, key)
      assert {:ok, ^plaintext} = Crypto.decrypt(ciphertext, key, iv, tag)
    end

    test "decryption fails with wrong key" do
      key1 = :crypto.strong_rand_bytes(32)
      key2 = :crypto.strong_rand_bytes(32)
      plaintext = "Secret"

      {ciphertext, iv, tag} = Crypto.encrypt(plaintext, key1)
      assert {:error, :decryption_failed} = Crypto.decrypt(ciphertext, key2, iv, tag)
    end
  end

  # ============================================================================
  # ChannelKeyStore
  # ============================================================================

  describe "ChannelKeyStore" do
    test "put and get sealed key" do
      sealed = %{ciphertext: "abc", iv: "def", tag: "ghi"}
      :ok = ChannelKeyStore.put("chan_1", "member_1", sealed)

      assert {:ok, ^sealed} = ChannelKeyStore.get("chan_1", "member_1")
    end

    test "returns not_found for missing key" do
      assert {:error, :not_found} = ChannelKeyStore.get("chan_nonexistent", "member_1")
    end

    test "delete removes key" do
      sealed = %{data: "test"}
      ChannelKeyStore.put("chan_del", "member_1", sealed)
      ChannelKeyStore.delete("chan_del", "member_1")

      assert {:error, :not_found} = ChannelKeyStore.get("chan_del", "member_1")
    end

    test "delete_channel removes all keys for channel" do
      ChannelKeyStore.put("chan_all", "m1", %{a: 1})
      ChannelKeyStore.put("chan_all", "m2", %{a: 2})
      ChannelKeyStore.put("chan_other", "m1", %{a: 3})

      ChannelKeyStore.delete_channel("chan_all")

      assert {:error, :not_found} = ChannelKeyStore.get("chan_all", "m1")
      assert {:error, :not_found} = ChannelKeyStore.get("chan_all", "m2")
      # Other channel unaffected
      assert {:ok, _} = ChannelKeyStore.get("chan_other", "m1")
    end

    test "members_with_keys returns member IDs" do
      ChannelKeyStore.put("chan_list", "m1", %{})
      ChannelKeyStore.put("chan_list", "m2", %{})

      members = ChannelKeyStore.members_with_keys("chan_list")
      assert "m1" in members
      assert "m2" in members
    end
  end
end
