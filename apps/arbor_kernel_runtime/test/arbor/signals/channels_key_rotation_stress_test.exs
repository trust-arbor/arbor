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

  alias Arbor.Signals.AuthorizedChannelsTestClient, as: Channels

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

    # ECIES mock (C2): seal/3 takes sender signing private; unseal/3 takes
    # sender signing public. Round-trips plaintext for channel-logic testing.
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

    def lookup("agent_" <> _rest = _agent_id), do: {:ok, :crypto.strong_rand_bytes(32)}
    def lookup(_agent_id), do: {:error, :not_found}
  end

  @stress_iterations 3
  @concurrent_senders 10

  setup do
    Arbor.Signals.TestCase.ensure_processes()
    Arbor.Signals.Config.Testing.isolate_namespace()
    Arbor.Signals.Config.Testing.put(:crypto_module, MockCrypto)
    Arbor.Signals.Config.Testing.put(:identity_registry_module, MockRegistry)

    Arbor.Signals.Config.Testing.put(
      :channel_principal_authorizer,
      Arbor.Signals.TestChannelPrincipalAuthorizer
    )

    Arbor.Signals.Config.Testing.put(:channel_rotate_on_leave, true)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helper: create channel with multiple members
  # ---------------------------------------------------------------------------

  defp create_channel_with_members(creator_id, member_ids) do
    {:ok, channel, :server_managed} = Channels.create("stress-channel", creator_id)

    # Add members by accepting mock invitations
    Enum.each(member_ids, fn member_id ->
      sender_keychain = %{
        agent_id: creator_id,
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)},
        signing_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, invitation} = Channels.invite(channel.id, member_id, sender_keychain)

      recipient_keychain = %{
        agent_id: member_id,
        encryption_keypair: %{private: :crypto.strong_rand_bytes(32)},
        signing_keypair: %{private: :crypto.strong_rand_bytes(32)}
      }

      {:ok, _ch, _key} =
        Channels.accept_invitation(
          channel.id,
          member_id,
          invitation.inviter_id,
          invitation.sealed_key,
          recipient_keychain
        )
    end)

    {channel.id, channel.key_version}
  end

  # ---------------------------------------------------------------------------
  # Stress: Concurrent sends don't lose messages
  # ---------------------------------------------------------------------------

  describe "concurrent sends" do
    test "all concurrent sends succeed on same channel" do
      Enum.each(1..@stress_iterations, fn _iteration ->
        creator = "agent_creator_#{:rand.uniform(100_000)}"

        members =
          for i <- 1..@concurrent_senders, do: "agent_member_#{i}_#{:rand.uniform(100_000)}"

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
    test "brief supervisor stalls do not reject an authorized send" do
      creator = "agent_creator_#{:rand.uniform(100_000)}"
      {channel_id, _key} = create_channel_with_members(creator, [])
      signals_supervisor = Process.whereis(Arbor.Signals.Supervisor)

      on_exit(fn ->
        if is_pid(signals_supervisor) and Process.alive?(signals_supervisor) do
          :sys.resume(signals_supervisor)
        end
      end)

      :ok = :sys.suspend(signals_supervisor)

      send_task =
        Task.async(fn ->
          Channels.send(channel_id, creator, :chat, %{text: "ownership proof waits"})
        end)

      assert eventually(fn -> supervisor_call_queued?(signals_supervisor) end)
      assert Task.yield(send_task, 100) == nil
      :ok = :sys.resume(signals_supervisor)
      assert :ok = Task.await(send_task, 2_000)
    end

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
      {channel_id, version_before} = create_channel_with_members(creator, [member])

      # Rotate
      {:ok, :server_managed, members_to_reinvite} = Channels.rotate_key(channel_id, creator)

      {:ok, rotated_channel} = Channels.get(channel_id)
      assert rotated_channel.key_version == version_before + 1

      # The member should be in the reinvite list
      assert member in members_to_reinvite
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
      versions =
        for _i <- 1..10 do
          {:ok, :server_managed, _members} = Channels.rotate_key(channel_id, creator)
          {:ok, channel} = Channels.get(channel_id)
          channel.key_version
        end

      assert versions == Enum.to_list(2..11)

      # Channel should still be functional
      {:ok, channel} = Channels.get(channel_id)
      # initial + 10 rotations
      assert channel.key_version == 11

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

      assert Enum.all?(results, fn {:ok, reference, _} -> reference == :server_managed end)

      # Final key version should reflect all rotations
      {:ok, channel} = Channels.get(channel_id)
      # initial + 5 rotations
      assert channel.key_version == 6
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

        {:ok, channel_before} = Channels.get(channel_id)

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

        # Key version should have advanced due to leave.
        {:ok, channel_after} = Channels.get(channel_id)
        assert channel_after.key_version > channel_before.key_version

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

  defp supervisor_call_queued?(supervisor) do
    case Process.info(supervisor, :message_queue_len) do
      {:message_queue_len, count} when count > 0 -> true
      _other -> false
    end
  end

  defp eventually(predicate, timeout_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(predicate, deadline)
  end

  defp do_eventually(predicate, deadline) do
    if predicate.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(5)
        do_eventually(predicate, deadline)
      end
    end
  end
end
