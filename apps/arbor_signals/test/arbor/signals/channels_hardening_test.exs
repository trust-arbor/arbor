defmodule Arbor.Signals.ChannelsHardeningTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Signals.Bus
  alias Arbor.Signals.Channels

  # Mock crypto module for testing
  defmodule MockCrypto do
    def seal(plaintext, _recipient_pub, _sender_priv) do
      %{ciphertext: plaintext, iv: <<0::96>>, tag: <<0::128>>, sender_public: <<0::256>>}
    end

    def unseal(%{ciphertext: ciphertext}, _recipient_priv) do
      {:ok, ciphertext}
    end

    def encrypt(plaintext, _key) do
      {plaintext, <<0::96>>, <<0::128>>}
    end

    def decrypt(ciphertext, _key, _iv, _tag) do
      {:ok, ciphertext}
    end
  end

  # Mock identity registry
  defmodule MockRegistry do
    def lookup_encryption_key(_agent_id) do
      {:ok, :crypto.strong_rand_bytes(32)}
    end
  end

  setup do
    # Configure mock modules
    Application.put_env(:arbor_signals, :crypto_module, MockCrypto)
    Application.put_env(:arbor_signals, :identity_registry_module, MockRegistry)
    Application.put_env(:arbor_signals, :channel_rotate_on_leave, true)

    # Bus and Channels are already started by the application

    on_exit(fn ->
      Application.delete_env(:arbor_signals, :crypto_module)
      Application.delete_env(:arbor_signals, :identity_registry_module)
      Application.delete_env(:arbor_signals, :channel_rotate_on_leave)
    end)

    :ok
  end

  describe "leave triggers key rotation" do
    test "leaving member causes key rotation when config enabled" do
      creator_id = "agent_creator"
      member_id = "agent_member"

      # Create channel
      {:ok, channel, _original_key} = Channels.create("test-channel", creator_id)
      channel_id = channel.id

      # Create mock keychain for inviting
      creator_keychain = %{
        agent_id: creator_id,
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      # Invite and accept member
      {:ok, invitation} = Channels.invite(channel_id, member_id, creator_keychain)

      member_keychain = %{
        agent_id: member_id,
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, _updated_channel, _key} =
        Channels.accept_invitation(channel_id, member_id, invitation.sealed_key, member_keychain)

      # Get key before leave
      {:ok, key_before} = Channels.get_key(channel_id, creator_id)

      # Member leaves
      :ok = Channels.leave(channel_id, member_id)

      # Key should have rotated
      {:ok, key_after} = Channels.get_key(channel_id, creator_id)
      assert key_after != key_before

      # Check key version incremented
      {:ok, channel_after} = Channels.get(channel_id)
      assert channel_after.key_version > channel.key_version
    end

    test "leaving member does not rotate key when config disabled" do
      Application.put_env(:arbor_signals, :channel_rotate_on_leave, false)

      creator_id = "agent_creator"
      member_id = "agent_member"

      {:ok, channel, _key} = Channels.create("test-channel", creator_id)
      channel_id = channel.id

      creator_keychain = %{
        agent_id: creator_id,
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, invitation} = Channels.invite(channel_id, member_id, creator_keychain)

      member_keychain = %{
        agent_id: member_id,
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, _channel, _key} =
        Channels.accept_invitation(channel_id, member_id, invitation.sealed_key, member_keychain)

      {:ok, key_before} = Channels.get_key(channel_id, creator_id)

      :ok = Channels.leave(channel_id, member_id)

      {:ok, key_after} = Channels.get_key(channel_id, creator_id)
      assert key_after == key_before
    end
  end

  describe "revoke function" do
    test "creator can revoke a member" do
      creator_id = "agent_creator"
      member_id = "agent_member"

      {:ok, channel, _key} = Channels.create("test-channel", creator_id)
      channel_id = channel.id

      creator_keychain = %{
        agent_id: creator_id,
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, invitation} = Channels.invite(channel_id, member_id, creator_keychain)

      member_keychain = %{
        agent_id: member_id,
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, _channel, _key} =
        Channels.accept_invitation(channel_id, member_id, invitation.sealed_key, member_keychain)

      # Verify member is in channel
      {:ok, channel_before} = Channels.get(channel_id)
      assert MapSet.member?(channel_before.members, member_id)

      # Revoke member
      :ok = Channels.revoke(channel_id, member_id, creator_id)

      # Verify member is removed
      {:ok, channel_after} = Channels.get(channel_id)
      refute MapSet.member?(channel_after.members, member_id)
    end

    test "revoked member is removed from channel" do
      creator_id = "agent_creator"
      member_id = "agent_member"

      {:ok, channel, _key} = Channels.create("test-channel", creator_id)
      channel_id = channel.id

      creator_keychain = %{
        agent_id: creator_id,
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, invitation} = Channels.invite(channel_id, member_id, creator_keychain)

      member_keychain = %{
        agent_id: member_id,
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, _channel, _key} =
        Channels.accept_invitation(channel_id, member_id, invitation.sealed_key, member_keychain)

      # Revoke member
      :ok = Channels.revoke(channel_id, member_id, creator_id)

      # Since revoked member is no longer in the channel, they shouldn't receive
      # key_redistributed signal for the new key. Only the creator (remaining member)
      # should receive it.
      {:ok, channel_after} = Channels.get(channel_id)
      refute MapSet.member?(channel_after.members, member_id)
    end

    test "revoke always triggers key rotation" do
      creator_id = "agent_creator"
      member_id = "agent_member"

      {:ok, channel, _key} = Channels.create("test-channel", creator_id)
      channel_id = channel.id

      creator_keychain = %{
        agent_id: creator_id,
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, invitation} = Channels.invite(channel_id, member_id, creator_keychain)

      member_keychain = %{
        agent_id: member_id,
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, _channel, _key} =
        Channels.accept_invitation(channel_id, member_id, invitation.sealed_key, member_keychain)

      {:ok, key_before} = Channels.get_key(channel_id, creator_id)

      :ok = Channels.revoke(channel_id, member_id, creator_id)

      {:ok, key_after} = Channels.get_key(channel_id, creator_id)
      assert key_after != key_before
    end

    test "non-creator cannot revoke" do
      creator_id = "agent_creator"
      member1_id = "agent_member1"
      member2_id = "agent_member2"

      {:ok, channel, _key} = Channels.create("test-channel", creator_id)
      channel_id = channel.id

      creator_keychain = %{
        agent_id: creator_id,
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      # Add both members
      {:ok, inv1} = Channels.invite(channel_id, member1_id, creator_keychain)
      {:ok, inv2} = Channels.invite(channel_id, member2_id, creator_keychain)

      member1_keychain = %{
        agent_id: member1_id,
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      member2_keychain = %{
        agent_id: member2_id,
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, _, _} = Channels.accept_invitation(channel_id, member1_id, inv1.sealed_key, member1_keychain)
      {:ok, _, _} = Channels.accept_invitation(channel_id, member2_id, inv2.sealed_key, member2_keychain)

      # Member1 tries to revoke member2 (should fail)
      result = Channels.revoke(channel_id, member2_id, member1_id)

      assert {:error, :not_creator} = result
    end

    test "cannot revoke self" do
      creator_id = "agent_creator"

      {:ok, channel, _key} = Channels.create("test-channel", creator_id)
      channel_id = channel.id

      result = Channels.revoke(channel_id, creator_id, creator_id)

      assert {:error, :cannot_revoke_self} = result
    end
  end

  describe "periodic rotation" do
    test "scheduled rotation fires on interval" do
      creator_id = "agent_creator"

      {:ok, channel, _key} = Channels.create("test-channel", creator_id)
      channel_id = channel.id

      # Configure very short interval for testing
      Application.put_env(:arbor_signals, :channel_auto_rotate_interval_ms, 50)

      # Schedule rotation
      :ok = Channels.schedule_rotation(channel_id, creator_id)

      {:ok, key_before} = Channels.get_key(channel_id, creator_id)

      # Wait for rotation
      Process.sleep(100)

      {:ok, key_after} = Channels.get_key(channel_id, creator_id)
      assert key_after != key_before
    end

    test "cancel_scheduled_rotation stops the timer" do
      creator_id = "agent_creator"

      {:ok, channel, _key} = Channels.create("test-channel", creator_id)
      channel_id = channel.id

      Application.put_env(:arbor_signals, :channel_auto_rotate_interval_ms, 50)

      :ok = Channels.schedule_rotation(channel_id, creator_id)
      :ok = Channels.cancel_scheduled_rotation(channel_id, creator_id)

      {:ok, key_before} = Channels.get_key(channel_id, creator_id)

      Process.sleep(100)

      {:ok, key_after} = Channels.get_key(channel_id, creator_id)
      assert key_after == key_before
    end
  end

  describe "key version tracking" do
    test "key version increments on each rotation" do
      creator_id = "agent_creator"

      {:ok, channel, _key} = Channels.create("test-channel", creator_id)
      channel_id = channel.id

      assert channel.key_version == 1

      {:ok, _new_key1, _members} = Channels.rotate_key(channel_id, creator_id)
      {:ok, channel2} = Channels.get(channel_id)
      assert channel2.key_version == 2

      {:ok, _new_key2, _members} = Channels.rotate_key(channel_id, creator_id)
      {:ok, channel3} = Channels.get(channel_id)
      assert channel3.key_version == 3
    end
  end

  describe "membership audit signals" do
    test "channel creation emits security signal" do
      test_pid = self()

      {:ok, sub_id} =
        Bus.subscribe("security.*", fn signal ->
          send(test_pid, {:signal, signal})
        end, principal_id: "test_principal")

      creator_id = "agent_creator"
      {:ok, channel, _key} = Channels.create("audit-test", creator_id)

      assert_receive {:signal, signal}, 100
      assert signal.category == :security
      assert signal.type == :channel_created
      # Data has string keys after JSON round-trip through encryption
      assert signal.data["channel_id"] == channel.id
      assert signal.data["agent_id"] == creator_id

      Bus.unsubscribe(sub_id)
    end

    test "member join emits security signal" do
      test_pid = self()

      {:ok, sub_id} =
        Bus.subscribe("security.*", fn signal ->
          send(test_pid, {:signal, signal})
        end, principal_id: "test_principal")

      creator_id = "agent_creator"
      member_id = "agent_member"

      {:ok, channel, _key} = Channels.create("audit-test", creator_id)
      channel_id = channel.id

      creator_keychain = %{
        agent_id: creator_id,
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, invitation} = Channels.invite(channel_id, member_id, creator_keychain)

      member_keychain = %{
        agent_id: member_id,
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, _, _} = Channels.accept_invitation(channel_id, member_id, invitation.sealed_key, member_keychain)

      # Collect signals
      signals = collect_signals(200)

      # Should have channel_created, channel_member_invited, channel_member_joined
      types = Enum.map(signals, & &1.type)
      assert :channel_created in types
      assert :channel_member_invited in types
      assert :channel_member_joined in types

      Bus.unsubscribe(sub_id)
    end

    test "member leave emits security signal" do
      test_pid = self()

      {:ok, sub_id} =
        Bus.subscribe("security.*", fn signal ->
          send(test_pid, {:signal, signal})
        end, principal_id: "test_principal")

      creator_id = "agent_creator"
      member_id = "agent_member"

      {:ok, channel, _key} = Channels.create("audit-test", creator_id)
      channel_id = channel.id

      creator_keychain = %{
        agent_id: creator_id,
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, invitation} = Channels.invite(channel_id, member_id, creator_keychain)

      member_keychain = %{
        agent_id: member_id,
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, _, _} = Channels.accept_invitation(channel_id, member_id, invitation.sealed_key, member_keychain)

      # Clear previous signals
      flush_messages()

      # Leave
      :ok = Channels.leave(channel_id, member_id)

      signals = collect_signals(200)
      types = Enum.map(signals, & &1.type)

      assert :channel_member_left in types
      assert :channel_key_rotated in types

      Bus.unsubscribe(sub_id)
    end

    test "key rotation reason is recorded" do
      test_pid = self()

      {:ok, sub_id} =
        Bus.subscribe("security.*", fn signal ->
          send(test_pid, {:signal, signal})
        end, principal_id: "test_principal")

      creator_id = "agent_creator"
      member_id = "agent_member"

      {:ok, channel, _key} = Channels.create("audit-test", creator_id)
      channel_id = channel.id

      creator_keychain = %{
        agent_id: creator_id,
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, invitation} = Channels.invite(channel_id, member_id, creator_keychain)

      member_keychain = %{
        agent_id: member_id,
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, _, _} = Channels.accept_invitation(channel_id, member_id, invitation.sealed_key, member_keychain)
      flush_messages()

      # Revoke triggers rotation with reason :member_revoked
      :ok = Channels.revoke(channel_id, member_id, creator_id)

      signals = collect_signals(200)

      rotation_signal = Enum.find(signals, &(&1.type == :channel_key_rotated))
      assert rotation_signal != nil
      # Data has string keys after JSON round-trip; reason becomes string too
      assert rotation_signal.data["reason"] == "member_revoked"

      Bus.unsubscribe(sub_id)
    end
  end

  # Helper functions

  defp collect_signals(timeout) do
    collect_signals([], timeout)
  end

  defp collect_signals(acc, timeout) do
    receive do
      {:signal, signal} ->
        collect_signals([signal | acc], timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end

  defp flush_messages do
    receive do
      _ -> flush_messages()
    after
      0 -> :ok
    end
  end
end
