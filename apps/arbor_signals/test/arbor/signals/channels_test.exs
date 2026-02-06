defmodule Arbor.Signals.ChannelsTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Signals.Channel
  alias Arbor.Signals.Channels

  # Mock modules for testing without arbor_security dependency
  defmodule MockCrypto do
    @moduledoc false

    def generate_encryption_keypair do
      :crypto.generate_key(:ecdh, :x25519)
    end

    def encrypt(plaintext, key) when byte_size(key) == 32 do
      iv = :crypto.strong_rand_bytes(12)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, "", 16, true)

      {ciphertext, iv, tag}
    end

    def decrypt(ciphertext, key, iv, tag) when byte_size(key) == 32 do
      case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, "", tag, false) do
        :error -> {:error, :decryption_failed}
        plaintext -> {:ok, plaintext}
      end
    end

    def seal(plaintext, _recipient_public, _sender_private) do
      # Simplified mock - just encode for testing
      %{
        ciphertext: plaintext,
        iv: <<0::96>>,
        tag: <<0::128>>,
        sender_public: <<0::256>>
      }
    end

    def unseal(%{ciphertext: plaintext}, _recipient_private) do
      {:ok, plaintext}
    end
  end

  defmodule MockRegistry do
    @moduledoc false

    def lookup_encryption_key("agent_" <> _rest = _agent_id) do
      {:ok, :crypto.strong_rand_bytes(32)}
    end

    def lookup_encryption_key(_agent_id) do
      {:error, :not_found}
    end
  end

  setup do
    # Configure mock modules
    Application.put_env(:arbor_signals, :crypto_module, MockCrypto)
    Application.put_env(:arbor_signals, :identity_registry_module, MockRegistry)

    on_exit(fn ->
      Application.delete_env(:arbor_signals, :crypto_module)
      Application.delete_env(:arbor_signals, :identity_registry_module)
    end)

    :ok
  end

  describe "create/3" do
    test "creates a new channel with generated key" do
      {:ok, channel, key} = Channels.create("Test Channel", "agent_creator")

      assert String.starts_with?(channel.id, "chan_")
      assert channel.name == "Test Channel"
      assert channel.creator_id == "agent_creator"
      assert Channel.member?(channel, "agent_creator")
      assert is_binary(key)
      assert byte_size(key) == 32
    end

    test "channels have unique IDs" do
      {:ok, channel1, _} = Channels.create("Channel 1", "agent_a")
      {:ok, channel2, _} = Channels.create("Channel 2", "agent_b")

      refute channel1.id == channel2.id
    end
  end

  describe "get/1" do
    test "returns channel by ID" do
      {:ok, created, _} = Channels.create("Lookup Test", "agent_lookup")
      {:ok, fetched} = Channels.get(created.id)

      assert fetched.id == created.id
      assert fetched.name == "Lookup Test"
    end

    test "returns error for non-existent channel" do
      assert {:error, :not_found} = Channels.get("chan_nonexistent")
    end
  end

  describe "invite/3" do
    test "creates an invitation for a valid invitee" do
      {:ok, channel, _key} = Channels.create("Invite Test", "agent_inviter")

      sender_keychain = %{
        agent_id: "agent_inviter",
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, invitation} = Channels.invite(channel.id, "agent_invitee", sender_keychain)

      assert invitation.channel_id == channel.id
      assert invitation.channel_name == "Invite Test"
      assert invitation.inviter_id == "agent_inviter"
      assert is_map(invitation.sealed_key)
      assert %DateTime{} = invitation.invited_at
    end

    test "fails when inviter is not a member" do
      {:ok, channel, _} = Channels.create("Member Check", "agent_owner")

      non_member_keychain = %{
        agent_id: "agent_outsider",
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      assert {:error, :not_a_member} =
               Channels.invite(channel.id, "agent_target", non_member_keychain)
    end

    test "fails for non-existent channel" do
      sender_keychain = %{
        agent_id: "agent_any",
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      assert {:error, :not_found} =
               Channels.invite("chan_nonexistent", "agent_target", sender_keychain)
    end
  end

  describe "accept_invitation/4" do
    test "adds invitee as member after accepting" do
      {:ok, channel, key} = Channels.create("Accept Test", "agent_host")

      host_keychain = %{
        agent_id: "agent_host",
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, invitation} = Channels.invite(channel.id, "agent_guest", host_keychain)

      guest_keychain = %{
        agent_id: "agent_guest",
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      # Mock sealed key contains the actual key as ciphertext in our mock
      sealed_key = %{invitation.sealed_key | ciphertext: key}

      {:ok, updated_channel, received_key} =
        Channels.accept_invitation(channel.id, "agent_guest", sealed_key, guest_keychain)

      assert Channel.member?(updated_channel, "agent_guest")
      assert received_key == key
    end
  end

  describe "send/4" do
    test "sends encrypted message on channel" do
      {:ok, channel, _} = Channels.create("Send Test", "agent_sender")

      result = Channels.send(channel.id, "agent_sender", :chat_message, %{text: "hello"})

      assert result == :ok
    end

    test "fails when sender is not a member" do
      {:ok, channel, _} = Channels.create("Auth Test", "agent_owner")

      assert {:error, :not_a_member} =
               Channels.send(channel.id, "agent_outsider", :chat_message, %{text: "hi"})
    end
  end

  describe "leave/2" do
    test "removes member from channel" do
      {:ok, channel, key} = Channels.create("Leave Test", "agent_alice")

      alice_keychain = %{
        agent_id: "agent_alice",
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, _} = Channels.invite(channel.id, "agent_bob", alice_keychain)

      bob_keychain = %{
        agent_id: "agent_bob",
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, invitation} = Channels.invite(channel.id, "agent_bob", alice_keychain)
      sealed_key = %{invitation.sealed_key | ciphertext: key}

      {:ok, _, _} = Channels.accept_invitation(channel.id, "agent_bob", sealed_key, bob_keychain)

      assert :ok = Channels.leave(channel.id, "agent_bob")

      {:ok, updated} = Channels.get(channel.id)
      refute Channel.member?(updated, "agent_bob")
    end

    test "assigns new creator when creator leaves" do
      {:ok, channel, key} = Channels.create("Creator Leave", "agent_alice")

      alice_keychain = %{
        agent_id: "agent_alice",
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, invitation} = Channels.invite(channel.id, "agent_bob", alice_keychain)

      bob_keychain = %{
        agent_id: "agent_bob",
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      sealed_key = %{invitation.sealed_key | ciphertext: key}
      {:ok, _, _} = Channels.accept_invitation(channel.id, "agent_bob", sealed_key, bob_keychain)

      assert :ok = Channels.leave(channel.id, "agent_alice")

      {:ok, updated} = Channels.get(channel.id)
      assert updated.creator_id == "agent_bob"
    end

    test "deletes channel when last member leaves" do
      {:ok, channel, _} = Channels.create("Delete Test", "agent_solo")

      assert :ok = Channels.leave(channel.id, "agent_solo")
      assert {:error, :not_found} = Channels.get(channel.id)
    end
  end

  describe "rotate_key/2" do
    test "generates new key and increments version" do
      {:ok, channel, original_key} = Channels.create("Rotate Test", "agent_admin")

      {:ok, new_key, members_to_reinvite} = Channels.rotate_key(channel.id, "agent_admin")

      refute new_key == original_key
      assert byte_size(new_key) == 32
      assert members_to_reinvite == []

      {:ok, updated} = Channels.get(channel.id)
      assert updated.key_version == 2
    end

    test "fails when requester is not the creator" do
      {:ok, channel, key} = Channels.create("Auth Rotate", "agent_owner")

      owner_keychain = %{
        agent_id: "agent_owner",
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, invitation} = Channels.invite(channel.id, "agent_member", owner_keychain)

      member_keychain = %{
        agent_id: "agent_member",
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      sealed_key = %{invitation.sealed_key | ciphertext: key}

      {:ok, _, _} =
        Channels.accept_invitation(channel.id, "agent_member", sealed_key, member_keychain)

      assert {:error, :not_creator} = Channels.rotate_key(channel.id, "agent_member")
    end

    test "returns list of members to reinvite" do
      {:ok, channel, key} = Channels.create("Reinvite Test", "agent_owner")

      owner_keychain = %{
        agent_id: "agent_owner",
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, invitation} = Channels.invite(channel.id, "agent_member", owner_keychain)

      member_keychain = %{
        agent_id: "agent_member",
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      sealed_key = %{invitation.sealed_key | ciphertext: key}

      {:ok, _, _} =
        Channels.accept_invitation(channel.id, "agent_member", sealed_key, member_keychain)

      {:ok, _, members_to_reinvite} = Channels.rotate_key(channel.id, "agent_owner")

      assert "agent_member" in members_to_reinvite
      refute "agent_owner" in members_to_reinvite
    end
  end

  describe "get_key/2" do
    test "returns key for channel member" do
      {:ok, channel, expected_key} = Channels.create("Key Test", "agent_member")

      {:ok, key} = Channels.get_key(channel.id, "agent_member")

      assert key == expected_key
    end

    test "fails for non-member" do
      {:ok, channel, _} = Channels.create("Key Auth", "agent_owner")

      assert {:error, :not_a_member} = Channels.get_key(channel.id, "agent_outsider")
    end
  end

  describe "list_channels/1" do
    test "returns channels the agent is a member of" do
      {:ok, channel1, _} = Channels.create("List Test 1", "agent_lister")
      {:ok, channel2, _} = Channels.create("List Test 2", "agent_lister")
      {:ok, _channel3, _} = Channels.create("Other Channel", "agent_other")

      channels = Channels.list_channels("agent_lister")

      ids = Enum.map(channels, & &1.id)
      assert channel1.id in ids
      assert channel2.id in ids
      assert length(channels) >= 2
    end

    test "returns empty list for agent with no channels" do
      channels = Channels.list_channels("agent_no_channels")

      assert channels == []
    end
  end

  describe "stats/0" do
    test "returns channel statistics" do
      # Ensure at least one channel exists
      Channels.create("Stats Test", "agent_stats")

      stats = Channels.stats()

      assert is_integer(stats.channels_created)
      assert is_integer(stats.invitations_sent)
      assert is_integer(stats.invitations_accepted)
      assert is_integer(stats.messages_sent)
      assert is_integer(stats.key_rotations)
      assert is_integer(stats.active_channels)
      assert is_integer(stats.total_members)
    end
  end
end
