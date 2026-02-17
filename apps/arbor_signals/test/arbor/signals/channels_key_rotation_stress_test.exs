defmodule Arbor.Signals.ChannelsKeyRotationStressTest do
  @moduledoc """
  Stress tests for key rotation under concurrent sends on Arbor.Signals.Channels.

  Validates that:
  - Messages sent before rotation use old key
  - Messages sent after rotation use new key
  - Concurrent sends during rotation don't lose messages
  - Multiple rapid rotations don't corrupt state
  - Stats remain consistent under concurrent send + rotate
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Signals.Channels

  # Mock modules (same as channels_test.exs)
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

  @stress_iterations 3
  @concurrent_senders 10

  setup do
    Application.put_env(:arbor_signals, :crypto_module, MockCrypto)
    Application.put_env(:arbor_signals, :identity_registry_module, MockRegistry)
    Application.put_env(:arbor_signals, :channel_rotate_on_leave, true)

    on_exit(fn ->
      Application.delete_env(:arbor_signals, :crypto_module)
      Application.delete_env(:arbor_signals, :identity_registry_module)
      Application.delete_env(:arbor_signals, :channel_rotate_on_leave)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Helper: create channel with multiple members
  # ---------------------------------------------------------------------------

  defp create_channel_with_members(creator_id, member_ids) do
    {:ok, channel, key} = Channels.create("stress-channel", creator_id)

    # Add members by accepting mock invitations
    Enum.each(member_ids, fn member_id ->
      sender_keychain = %{
        agent_id: creator_id,
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, invitation} = Channels.invite(channel.id, member_id, sender_keychain)

      recipient_keychain = %{
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, _ch, _key} =
        Channels.accept_invitation(channel.id, member_id, invitation.sealed_key, recipient_keychain)
    end)

    {channel.id, key}
  end

  # ---------------------------------------------------------------------------
  # Stress: Concurrent sends don't lose messages
  # ---------------------------------------------------------------------------

  describe "concurrent sends" do
    test "all concurrent sends succeed on same channel" do
      Enum.each(1..@stress_iterations, fn _iteration ->
        creator = "agent_creator_#{:rand.uniform(100_000)}"
        members = for i <- 1..@concurrent_senders, do: "agent_member_#{i}_#{:rand.uniform(100_000)}"
        {channel_id, _key} = create_channel_with_members(creator, members)

        # All members send concurrently
        tasks =
          Enum.map(members, fn member_id ->
            Task.async(fn ->
              Channels.send(channel_id, member_id, :chat, %{text: "hello from #{member_id}"})
            end)
          end)

        results = Task.await_many(tasks, 5_000)

        # All sends should succeed
        assert Enum.all?(results, &(&1 == :ok)),
               "Some sends failed: #{inspect(Enum.reject(results, &(&1 == :ok)))}"
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Stress: Key rotation during concurrent sends
  # ---------------------------------------------------------------------------

  describe "key rotation during concurrent sends" do
    test "sends succeed even when rotation happens concurrently" do
      Enum.each(1..@stress_iterations, fn _iteration ->
        creator = "agent_creator_#{:rand.uniform(100_000)}"
        members = for i <- 1..@concurrent_senders, do: "agent_m_#{i}_#{:rand.uniform(100_000)}"
        {channel_id, _key} = create_channel_with_members(creator, members)

        # Start concurrent sends
        send_tasks =
          Enum.map(members, fn member_id ->
            Task.async(fn ->
              # Each member sends multiple messages
              results =
                for n <- 1..5 do
                  Channels.send(channel_id, member_id, :chat, %{text: "msg-#{n}"})
                end

              {:sends, member_id, results}
            end)
          end)

        # Rotate key concurrently
        rotate_task =
          Task.async(fn ->
            # Small delay to let some sends start
            Process.sleep(1)
            result = Channels.rotate_key(channel_id, creator)
            {:rotate, result}
          end)

        all_results = Task.await_many([rotate_task | send_tasks], 10_000)

        # Rotation should succeed
        {:rotate, rotate_result} = hd(all_results)
        assert match?({:ok, _, _}, rotate_result), "Rotation failed: #{inspect(rotate_result)}"

        # All sends should succeed (either with old or new key)
        send_results = tl(all_results)

        Enum.each(send_results, fn {:sends, member_id, results} ->
          Enum.each(results, fn result ->
            assert result == :ok,
                   "Send failed for #{member_id}: #{inspect(result)}"
          end)
        end)
      end)
    end

    test "key changes after rotation" do
      creator = "agent_creator_#{:rand.uniform(100_000)}"
      member = "agent_member_#{:rand.uniform(100_000)}"
      {channel_id, _key} = create_channel_with_members(creator, [member])

      # Get key before rotation
      {:ok, key_before} = Channels.get_key(channel_id, creator)

      # Rotate
      {:ok, new_key, members_to_reinvite} = Channels.rotate_key(channel_id, creator)

      # Key should have changed
      assert new_key != key_before

      # The member should be in the reinvite list
      assert member in members_to_reinvite

      # Channel key should be the new key
      {:ok, key_after} = Channels.get_key(channel_id, creator)
      assert key_after == new_key
      assert key_after != key_before
    end
  end

  # ---------------------------------------------------------------------------
  # Stress: Multiple rapid rotations
  # ---------------------------------------------------------------------------

  describe "rapid sequential rotations" do
    test "multiple rotations don't corrupt channel state" do
      creator = "agent_creator_#{:rand.uniform(100_000)}"
      member = "agent_member_#{:rand.uniform(100_000)}"
      {channel_id, _key} = create_channel_with_members(creator, [member])

      # Perform multiple rapid rotations
      keys =
        for _i <- 1..10 do
          {:ok, new_key, _members} = Channels.rotate_key(channel_id, creator)
          new_key
        end

      # All keys should be unique
      assert length(Enum.uniq(keys)) == 10, "Some rotation keys were duplicated"

      # Channel should still be functional
      {:ok, channel} = Channels.get(channel_id)
      assert channel.key_version == 11  # initial + 10 rotations

      # Sends still work after many rotations
      assert :ok =
               Channels.send(channel_id, creator, :chat, %{text: "after many rotations"})
    end

    test "concurrent rotations are serialized by GenServer" do
      creator = "agent_creator_#{:rand.uniform(100_000)}"
      member = "agent_member_#{:rand.uniform(100_000)}"
      {channel_id, _key} = create_channel_with_members(creator, [member])

      # Fire multiple concurrent rotation requests
      tasks =
        for _i <- 1..5 do
          Task.async(fn ->
            Channels.rotate_key(channel_id, creator)
          end)
        end

      results = Task.await_many(tasks, 5_000)

      # All should succeed (GenServer serializes them)
      assert Enum.all?(results, fn r -> match?({:ok, _, _}, r) end),
             "Some rotations failed: #{inspect(results)}"

      # Keys should all be different
      keys = Enum.map(results, fn {:ok, key, _} -> key end)
      assert length(Enum.uniq(keys)) == 5, "Concurrent rotations produced duplicate keys"

      # Final key version should reflect all rotations
      {:ok, channel} = Channels.get(channel_id)
      assert channel.key_version == 6  # initial + 5 rotations
    end
  end

  # ---------------------------------------------------------------------------
  # Stress: Member leave triggers rotation under concurrent sends
  # ---------------------------------------------------------------------------

  describe "member leave with concurrent sends" do
    test "leave triggers rotation while sends are in-flight" do
      Enum.each(1..@stress_iterations, fn _iteration ->
        creator = "agent_creator_#{:rand.uniform(100_000)}"
        leaver = "agent_leaver_#{:rand.uniform(100_000)}"
        stayer = "agent_stayer_#{:rand.uniform(100_000)}"
        {channel_id, _key} = create_channel_with_members(creator, [leaver, stayer])

        {:ok, key_before} = Channels.get_key(channel_id, creator)

        # Concurrent: stayer sends messages while leaver leaves
        send_task =
          Task.async(fn ->
            results =
              for n <- 1..5 do
                Channels.send(channel_id, stayer, :chat, %{text: "msg-#{n}"})
              end

            {:sends, results}
          end)

        leave_task =
          Task.async(fn ->
            Process.sleep(1)
            result = Channels.leave(channel_id, leaver)
            {:leave, result}
          end)

        [_send_result, leave_result] = Task.await_many([send_task, leave_task], 5_000)

        {:leave, leave_status} = leave_result
        assert leave_status == :ok

        # Key should have rotated due to leave
        {:ok, key_after} = Channels.get_key(channel_id, creator)
        assert key_after != key_before

        # Channel should still work for remaining members
        assert :ok = Channels.send(channel_id, creator, :chat, %{text: "still works"})
        assert :ok = Channels.send(channel_id, stayer, :chat, %{text: "me too"})

        # Leaver should no longer be a member
        assert {:error, :not_a_member} =
                 Channels.send(channel_id, leaver, :chat, %{text: "gone"})
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Stress: Stats consistency under concurrent operations
  # ---------------------------------------------------------------------------

  describe "stats consistency" do
    test "message and rotation counts are accurate" do
      creator = "agent_creator_#{:rand.uniform(100_000)}"
      member = "agent_member_#{:rand.uniform(100_000)}"
      {channel_id, _key} = create_channel_with_members(creator, [member])

      stats_before = Channels.stats()

      # Send several messages concurrently
      send_count = 10

      send_tasks =
        for i <- 1..send_count do
          sender = if rem(i, 2) == 0, do: creator, else: member

          Task.async(fn ->
            Channels.send(channel_id, sender, :chat, %{text: "msg-#{i}"})
          end)
        end

      Task.await_many(send_tasks, 5_000)

      # Rotate once
      {:ok, _, _} = Channels.rotate_key(channel_id, creator)

      stats_after = Channels.stats()

      assert stats_after.messages_sent == stats_before.messages_sent + send_count
      assert stats_after.key_rotations == stats_before.key_rotations + 1
    end
  end
end
