defmodule Arbor.Signals.BusEncryptionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Signals.Bus
  alias Arbor.Signals.Signal
  alias Arbor.Signals.TopicKeys

  # Test authorizer that allows everything
  defmodule AllowAllAuthorizer do
    @behaviour Arbor.Signals.Behaviours.SubscriptionAuthorizer

    @impl true
    def authorize_subscription(_principal_id, _topic) do
      {:ok, :authorized}
    end
  end

  setup do
    Arbor.Signals.TestCase.ensure_processes()

    # Use our permissive authorizer
    original_authorizer = Application.get_env(:arbor_signals, :authorizer)
    Application.put_env(:arbor_signals, :authorizer, AllowAllAuthorizer)

    on_exit(fn ->
      if original_authorizer do
        Application.put_env(:arbor_signals, :authorizer, original_authorizer)
      else
        Application.delete_env(:arbor_signals, :authorizer)
      end
    end)

    :ok
  end

  describe "restricted topic encryption" do
    test "encrypts data for restricted topics at publish time" do
      test_pid = self()

      # Subscribe to security topic (restricted)
      {:ok, sub_id} =
        Bus.subscribe(
          "security.*",
          fn signal ->
            send(test_pid, {:received, signal})
            :ok
          end,
          async: false,
          principal_id: "agent_test_enc"
        )

      # Publish a security signal
      original_data = %{event: "login_attempt", user: "alice"}
      signal = Signal.new(:security, :auth_event, original_data)
      Bus.publish(signal)

      # Subscriber should receive decrypted data
      assert_receive {:received, received_signal}, 1000

      # Verify the data was decrypted properly (comes back as string keys after JSON round-trip)
      assert received_signal.data["event"] == "login_attempt"
      assert received_signal.data["user"] == "alice"

      Bus.unsubscribe(sub_id)
    end

    test "encrypts data for identity topic" do
      test_pid = self()

      {:ok, sub_id} =
        Bus.subscribe(
          "identity.*",
          fn signal ->
            send(test_pid, {:identity_received, signal})
            :ok
          end,
          async: false,
          principal_id: "agent_identity_test"
        )

      original_data = %{agent_id: "agent_123", action: "key_rotation"}
      signal = Signal.new(:identity, :key_rotated, original_data)
      Bus.publish(signal)

      assert_receive {:identity_received, received_signal}, 1000

      assert received_signal.data["agent_id"] == "agent_123"
      assert received_signal.data["action"] == "key_rotation"

      Bus.unsubscribe(sub_id)
    end

    test "does not encrypt non-restricted topics" do
      test_pid = self()

      {:ok, sub_id} =
        Bus.subscribe(
          "activity.*",
          fn signal ->
            send(test_pid, {:activity_received, signal})
            :ok
          end,
          async: false
        )

      # Publish a non-restricted activity signal
      original_data = %{task_id: "task_123", status: "completed"}
      signal = Signal.new(:activity, :task_completed, original_data)
      Bus.publish(signal)

      # Subscriber should receive original data (atom keys, not encrypted)
      assert_receive {:activity_received, received_signal}, 1000

      assert received_signal.data == original_data

      Bus.unsubscribe(sub_id)
    end

    test "empty data is not encrypted" do
      test_pid = self()

      {:ok, sub_id} =
        Bus.subscribe(
          "security.*",
          fn signal ->
            send(test_pid, {:empty_received, signal})
            :ok
          end,
          async: false,
          principal_id: "agent_empty_test"
        )

      signal = Signal.new(:security, :heartbeat, %{})
      Bus.publish(signal)

      assert_receive {:empty_received, received_signal}, 1000

      assert received_signal.data == %{}

      Bus.unsubscribe(sub_id)
    end
  end

  describe "encryption key management" do
    test "uses same topic key for multiple signals" do
      # Get or create key for security topic
      {:ok, key_info1} = TopicKeys.get_or_create(:security)
      {:ok, key_info2} = TopicKeys.get(:security)

      assert key_info1.key == key_info2.key
      assert key_info1.version == key_info2.version
    end

    test "different topics use different keys" do
      {:ok, security_key} = TopicKeys.get_or_create(:security)
      {:ok, identity_key} = TopicKeys.get_or_create(:identity)

      refute security_key.key == identity_key.key
    end
  end

  describe "wildcard subscriptions with encryption" do
    test "wildcard subscriber receives decrypted restricted signals" do
      test_pid = self()

      {:ok, sub_id} =
        Bus.subscribe(
          "*",
          fn signal ->
            send(test_pid, {:wildcard, signal.category, signal.data})
            :ok
          end,
          async: false,
          principal_id: "agent_wildcard_enc"
        )

      # Send a security signal
      Bus.publish(Signal.new(:security, :test_event, %{secret: "value"}))

      # Wait for the signal
      assert_receive {:wildcard, :security, data}, 1000

      # Should be decrypted
      assert data["secret"] == "value"

      Bus.unsubscribe(sub_id)
    end
  end

  describe "channel-encrypted signals (OQ-7 regression)" do
    alias Arbor.Signals.Channels

    test "security regression (OQ-7): non-member subscriber cannot decrypt channel-encrypted signal" do
      # OQ-7: pre-fix, Bus.maybe_decrypt_channel_signal called
      # Channels.get_key(channel_id, signal.source) — keyed on the SENDER.
      # Anyone subscribed to the topic received decrypted plaintext as long
      # as the SENDER was a member, regardless of whether the SUBSCRIBER was.
      # The fix routes through Channels.decrypt_for_member/3 using the
      # subscriber's principal_id — non-members get __decryption_failed__,
      # not plaintext.
      Bus.reset()

      member = "agent_oq7_member_#{System.unique_integer([:positive])}"
      non_member = "agent_oq7_outsider_#{System.unique_integer([:positive])}"

      {:ok, channel, key} =
        Channels.create("oq7_channel_#{System.unique_integer([:positive])}", member)

      plaintext = Jason.encode!(%{"secret" => "oq7_value"})
      iv = :crypto.strong_rand_bytes(12)

      {ct, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, "", 16, true)

      payload = %{ciphertext: ct, iv: iv, tag: tag}

      parent = self()
      handler = fn signal -> send(parent, {:oq7_signal, signal.data}) end

      Application.put_env(
        :arbor_signals,
        :subscription_authorizer_module,
        Arbor.Signals.BusEncryptionTest.AllowAllAuthorizer
      )

      {:ok, sub_id} = Bus.subscribe("oq7.*", handler, principal_id: non_member)

      signal_a = %{
        Signal.new(:oq7, :test, %{
          __channel_encrypted__: true,
          channel_id: channel.id,
          sender_id: member,
          payload: payload
        })
        | source: member
      }

      Bus.publish(signal_a)

      assert_receive {:oq7_signal, delivered_data}, 1000

      # Pre-fix: get_key(channel_id, signal.source) succeeded because the
      # SENDER was a member, and the non-member subscriber received the
      # decrypted plaintext. The fix denies — delivered_data shows
      # __decryption_failed__, not the cleartext.
      assert Map.has_key?(delivered_data, :__decryption_failed__) or
               Map.has_key?(delivered_data, "__decryption_failed__"),
             "Non-member subscriber must NOT receive plaintext — OQ-7 regression. " <>
               "Got: #{inspect(delivered_data)}"

      refute Map.has_key?(delivered_data, "secret")
      refute Map.has_key?(delivered_data, :secret)

      Bus.unsubscribe(sub_id)
    end

    test "subscriber who IS a member receives decrypted plaintext" do
      Bus.reset()

      member = "agent_oq7_member2_#{System.unique_integer([:positive])}"

      {:ok, channel, key} =
        Channels.create("oq7_channel_pos_#{System.unique_integer([:positive])}", member)

      plaintext = Jason.encode!(%{"secret" => "oq7_member_value"})
      iv = :crypto.strong_rand_bytes(12)

      {ct, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, "", 16, true)

      payload = %{ciphertext: ct, iv: iv, tag: tag}

      parent = self()
      handler = fn signal -> send(parent, {:oq7_signal_pos, signal.data}) end

      Application.put_env(
        :arbor_signals,
        :subscription_authorizer_module,
        Arbor.Signals.BusEncryptionTest.AllowAllAuthorizer
      )

      {:ok, sub_id} = Bus.subscribe("oq7pos.*", handler, principal_id: member)

      signal_b = %{
        Signal.new(:oq7pos, :test, %{
          __channel_encrypted__: true,
          channel_id: channel.id,
          sender_id: member,
          payload: payload
        })
        | source: member
      }

      Bus.publish(signal_b)

      assert_receive {:oq7_signal_pos, delivered_data}, 1000

      assert delivered_data["secret"] == "oq7_member_value",
             "Member subscriber must receive decrypted plaintext. Got: #{inspect(delivered_data)}"

      Bus.unsubscribe(sub_id)
    end
  end
end
