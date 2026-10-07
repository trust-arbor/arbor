defmodule Arbor.Signals.ChannelsTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Signals.Channel
  alias Arbor.Signals.AuthorizedChannelsTestClient, as: Channels
  alias Arbor.Signals.Channels, as: PublicChannels

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

    # ECIES mock (C2): seal/3 takes the sender's signing private key; unseal/3
    # takes the sender's signing public key. The mock ignores the crypto and
    # just round-trips the plaintext for channel-logic testing.
    def seal(plaintext, _recipient_public, _sender_sign_private) do
      %{
        v: 2,
        ciphertext: plaintext,
        iv: <<0::96>>,
        tag: <<0::128>>,
        ephemeral_public: <<0::256>>,
        signature: <<0::512>>
      }
    end

    def unseal(%{ciphertext: plaintext}, _recipient_private, _sender_sign_public) do
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

    # Signing-key lookup used by accept_invitation to verify the inviter (C2).
    def lookup("agent_" <> _rest = _agent_id), do: {:ok, :crypto.strong_rand_bytes(32)}
    def lookup(_agent_id), do: {:error, :not_found}
  end

  setup do
    # Ensure signal processes are running (may have crashed in umbrella test runs)
    Arbor.Signals.TestCase.ensure_processes()
    Arbor.Signals.Config.Testing.isolate_namespace()
    Arbor.Signals.Config.Testing.put(:crypto_module, MockCrypto)
    Arbor.Signals.Config.Testing.put(:identity_registry_module, MockRegistry)

    Arbor.Signals.Config.Testing.put(
      :channel_principal_authorizer,
      Arbor.Signals.TestChannelPrincipalAuthorizer
    )

    :ok
  end

  describe "create/3" do
    test "creates a new channel while retaining its generated key" do
      {:ok, channel, key_reference} = Channels.create("Test Channel", "agent_creator")

      assert String.starts_with?(channel.id, "chan_")
      assert channel.name == "Test Channel"
      assert channel.creator_id == "agent_creator"
      assert Channel.member?(channel, "agent_creator")
      assert key_reference == :server_managed
    end

    test "channels have unique IDs" do
      {:ok, channel1, _} = Channels.create("Channel 1", "agent_a")
      {:ok, channel2, _} = Channels.create("Channel 2", "agent_b")

      refute channel1.id == channel2.id
    end

    @tag :security_regression
    test "security regression: caller-asserted member ids cannot authorize channel operations" do
      creator = "agent_spoofed_creator"
      {:ok, channel, :server_managed} = Channels.create("Spoof Boundary", creator)

      assert {:error, :authenticated_principal_required} =
               PublicChannels.create("Forged Creator", creator)

      assert {:error, :authenticated_principal_required} =
               PublicChannels.invite(channel.id, "agent_target", %{agent_id: creator})

      assert {:error, :authenticated_principal_required} =
               PublicChannels.accept_invitation(
                 channel.id,
                 "agent_target",
                 creator,
                 %{},
                 %{}
               )

      assert {:error, :authenticated_principal_required} =
               PublicChannels.send(channel.id, creator, :chat_message, %{text: "forged"})

      assert {:error, :authenticated_principal_required} =
               PublicChannels.leave(channel.id, creator)

      assert {:error, :authenticated_principal_required} =
               PublicChannels.revoke(channel.id, "agent_target", creator)

      assert {:error, :authenticated_principal_required} =
               PublicChannels.rotate_key(channel.id, creator)

      assert {:error, :authenticated_principal_required} =
               PublicChannels.schedule_rotation(channel.id, creator)

      assert {:error, :authenticated_principal_required} =
               PublicChannels.cancel_scheduled_rotation(channel.id, creator)

      assert {:error, :authenticated_principal_required} =
               PublicChannels.decrypt_for_member(channel.id, creator, %{})

      assert {:error, :authenticated_principal_required} =
               PublicChannels.list_channels(creator)
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
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)},
        signing_keypair: %{private: :crypto.strong_rand_bytes(32)}
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
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)},
        signing_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      assert {:error, :not_a_member} =
               Channels.invite(channel.id, "agent_target", non_member_keychain)
    end

    test "fails for non-existent channel" do
      sender_keychain = %{
        agent_id: "agent_any",
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)},
        signing_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      assert {:error, :not_found} =
               Channels.invite("chan_nonexistent", "agent_target", sender_keychain)
    end
  end

  describe "accept_invitation/4" do
    test "adds invitee as member after accepting" do
      {:ok, channel, :server_managed} = Channels.create("Accept Test", "agent_host")

      host_keychain = %{
        agent_id: "agent_host",
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)},
        signing_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, invitation} = Channels.invite(channel.id, "agent_guest", host_keychain)

      guest_keychain = %{
        agent_id: "agent_guest",
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)},
        signing_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, updated_channel, key_reference} =
        Channels.accept_invitation(
          channel.id,
          "agent_guest",
          invitation.inviter_id,
          invitation.sealed_key,
          guest_keychain
        )

      assert Channel.member?(updated_channel, "agent_guest")
      assert key_reference == :server_managed
    end

    @tag :security_regression
    test "security regression: invitation is pinned to the recipient identity and cannot replay" do
      {:ok, channel, _key} = Channels.create("Pinned Invite", "agent_host")

      host_keychain = %{
        agent_id: "agent_host",
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)},
        signing_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      guest_keychain = %{
        agent_id: "agent_guest",
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)},
        signing_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, invitation} = Channels.invite(channel.id, "agent_guest", host_keychain)

      assert {:error, :recipient_identity_mismatch} =
               Channels.accept_invitation(
                 channel.id,
                 "agent_attacker",
                 invitation.inviter_id,
                 invitation.sealed_key,
                 guest_keychain
               )

      assert {:ok, _, _} =
               Channels.accept_invitation(
                 channel.id,
                 "agent_guest",
                 invitation.inviter_id,
                 invitation.sealed_key,
                 guest_keychain
               )

      assert {:error, :invitation_not_pending} =
               Channels.accept_invitation(
                 channel.id,
                 "agent_guest",
                 invitation.inviter_id,
                 invitation.sealed_key,
                 guest_keychain
               )
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
      {:ok, channel, :server_managed} = Channels.create("Leave Test", "agent_alice")

      alice_keychain = %{
        agent_id: "agent_alice",
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)},
        signing_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, _} = Channels.invite(channel.id, "agent_bob", alice_keychain)

      bob_keychain = %{
        agent_id: "agent_bob",
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)},
        signing_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, invitation} = Channels.invite(channel.id, "agent_bob", alice_keychain)

      {:ok, _, _} =
        Channels.accept_invitation(
          channel.id,
          "agent_bob",
          invitation.inviter_id,
          invitation.sealed_key,
          bob_keychain
        )

      assert :ok = Channels.leave(channel.id, "agent_bob")

      {:ok, updated} = Channels.get(channel.id)
      refute Channel.member?(updated, "agent_bob")
    end

    test "assigns new creator when creator leaves" do
      {:ok, channel, :server_managed} = Channels.create("Creator Leave", "agent_alice")

      alice_keychain = %{
        agent_id: "agent_alice",
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)},
        signing_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, invitation} = Channels.invite(channel.id, "agent_bob", alice_keychain)

      bob_keychain = %{
        agent_id: "agent_bob",
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)},
        signing_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, _, _} =
        Channels.accept_invitation(
          channel.id,
          "agent_bob",
          invitation.inviter_id,
          invitation.sealed_key,
          bob_keychain
        )

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
    test "retains the new key and increments version" do
      {:ok, channel, :server_managed} = Channels.create("Rotate Test", "agent_admin")

      {:ok, key_reference, members_to_reinvite} =
        Channels.rotate_key(channel.id, "agent_admin")

      assert key_reference == :server_managed
      assert members_to_reinvite == []

      {:ok, updated} = Channels.get(channel.id)
      assert updated.key_version == 2
    end

    test "fails when requester is not the creator" do
      {:ok, channel, :server_managed} = Channels.create("Auth Rotate", "agent_owner")

      owner_keychain = %{
        agent_id: "agent_owner",
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)},
        signing_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, invitation} = Channels.invite(channel.id, "agent_member", owner_keychain)

      member_keychain = %{
        agent_id: "agent_member",
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)},
        signing_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, _, _} =
        Channels.accept_invitation(
          channel.id,
          "agent_member",
          invitation.inviter_id,
          invitation.sealed_key,
          member_keychain
        )

      assert {:error, :not_creator} = Channels.rotate_key(channel.id, "agent_member")
    end

    test "returns list of members to reinvite" do
      {:ok, channel, :server_managed} = Channels.create("Reinvite Test", "agent_owner")

      owner_keychain = %{
        agent_id: "agent_owner",
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)},
        signing_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, invitation} = Channels.invite(channel.id, "agent_member", owner_keychain)

      member_keychain = %{
        agent_id: "agent_member",
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)},
        signing_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, _, _} =
        Channels.accept_invitation(
          channel.id,
          "agent_member",
          invitation.inviter_id,
          invitation.sealed_key,
          member_keychain
        )

      {:ok, _, members_to_reinvite} = Channels.rotate_key(channel.id, "agent_owner")

      assert "agent_member" in members_to_reinvite
      refute "agent_owner" in members_to_reinvite
    end

    @tag :security_regression
    test "security regression: rotation emits no self-authenticated key redistribution" do
      test_pid = self()

      {:ok, subscription_id} =
        Arbor.Signals.Bus.subscribe(
          "channel.key_redistributed",
          fn signal -> send(test_pid, {:redistributed, signal}) end,
          principal_id: "channel_rotation_regression",
          async: false
        )

      {:ok, channel, _key} = Channels.create("No TOFU Rotation", "agent_owner")
      assert {:ok, _new_key, []} = Channels.rotate_key(channel.id, "agent_owner")

      refute_received {:redistributed, _signal}
      :ok = Arbor.Signals.Bus.unsubscribe(subscription_id)
    end
  end

  describe "get_key/2" do
    @tag :security_regression
    test "security regression: raw keys are never exported for asserted member ids" do
      {:ok, channel, _expected_key} = Channels.create("Key Test", "agent_member")

      assert {:error, :raw_key_export_disabled} =
               Channels.get_key(channel.id, "agent_member")
    end

    test "fails closed identically for a non-member" do
      {:ok, channel, _} = Channels.create("Key Auth", "agent_owner")

      assert {:error, :raw_key_export_disabled} =
               Channels.get_key(channel.id, "agent_outsider")
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

  describe "decrypt_for_member/3" do
    setup do
      n = System.unique_integer([:positive])
      creator = "agent_h4_creator_#{n}"
      stranger = "agent_h4_stranger_#{n}"

      {:ok, channel, :server_managed} = Channels.create("h4_test_channel_#{n}", creator)

      payload = %{
        ciphertext: :crypto.strong_rand_bytes(32),
        iv: :crypto.strong_rand_bytes(12),
        tag: :crypto.strong_rand_bytes(16)
      }

      %{
        channel_id: channel.id,
        creator: creator,
        stranger: stranger,
        payload: payload
      }
    end

    test "security regression (H4): non-members cannot decrypt",
         %{channel_id: channel_id, stranger: stranger, payload: payload} do
      # H4: the new server-side decrypt path enforces membership inside the
      # GenServer. A caller asserting a non-member id gets {:error, :not_a_member}
      # rather than receiving plaintext or — under the old get_key/2 path —
      # receiving the raw symmetric key for an unauthorized id.
      assert {:error, :not_a_member} =
               Channels.decrypt_for_member(channel_id, stranger, payload),
             "Non-member must not be able to decrypt — H4 regression"
    end

    test "garbled payload fails closed",
         %{channel_id: channel_id, creator: creator, payload: garbled} do
      assert {:error, :decryption_failed} =
               Channels.decrypt_for_member(channel_id, creator, garbled)
    end
  end
end
