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
end
