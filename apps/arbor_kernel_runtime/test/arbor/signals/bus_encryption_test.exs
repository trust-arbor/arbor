defmodule Arbor.Signals.BusEncryptionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Signals.{Bus, Relay, Store}
  alias Arbor.Signals.Config.Testing
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

  defmodule SecuritySyncPublisher do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, name: Keyword.fetch!(opts, :name))
    end

    def subscribe(pid, role, event) do
      GenServer.call(pid, {:subscribe, role, event})
    end

    def emit(pid, category, type, data, opts) do
      GenServer.call(pid, {:emit, category, type, data, opts})
    end

    @impl true
    def init(:ok) do
      Process.flag(:sensitive, true)
      {:ok, %{}}
    end

    @impl true
    def handle_call({:subscribe, role, event}, _from, state) do
      {:reply, Arbor.Signals.subscribe_security_sync(role, event), state}
    end

    def handle_call({:emit, category, type, data, opts}, _from, state) do
      {:reply, Arbor.Signals.emit(category, type, data, opts), state}
    end

    @impl true
    def handle_info({:signal_received, _delivery_ref, _signal}, state), do: {:noreply, state}
  end

  setup do
    Arbor.Signals.TestCase.ensure_processes()

    Testing.isolate_namespace()
    Testing.put(:authorizer, AllowAllAuthorizer)

    Testing.put(
      :channel_principal_authorizer,
      Arbor.Signals.TestChannelPrincipalAuthorizer
    )

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

    test "security regression: revocation sync survives node-local topic key changes" do
      publisher = start_security_sync_publisher()

      marker = "cap_revocation_#{System.unique_integer([:positive])}"

      assert :ok =
               SecuritySyncPublisher.emit(
                 publisher,
                 :security,
                 :capability_revoked,
                 %{capability_ids: [marker], origin_node: node()},
                 async: false,
                 scope: :cluster
               )

      {:ok, [stored | _]} = Store.recent(type: :capability_revoked, limit: 1)
      assert stored.data.capability_ids == [marker]
      refute Map.has_key?(stored.data, :__encrypted__)

      # A peer has an independent key. Rotating ours models that mismatch;
      # portable revocation payloads must not depend on either node's key.
      {:ok, _rotated} = TopicKeys.rotate(:security)
      test_pid = self()

      {:ok, sub_id} =
        Bus.subscribe(
          "security.capability_revoked",
          fn signal ->
            send(test_pid, {:remote_revocation, signal})
            :ok
          end,
          async: false,
          principal_id: "agent_revocation_sync_regression"
        )

      assert :ok = Relay.receive_batch_fixture([stored], :peer@host)

      assert_receive {:remote_revocation, delivered}, 1_000
      assert delivered.data.capability_ids == [marker]
      assert delivered.data.origin_node == :peer@host
      refute Map.has_key?(delivered.data, :__decryption_failed__)

      Bus.unsubscribe(sub_id)
    end
  end

  defp start_security_sync_publisher do
    child_id = {SecuritySyncPublisher, System.unique_integer([:positive])}

    child_spec =
      Supervisor.child_spec(
        {SecuritySyncPublisher, name: SecuritySyncPublisher},
        id: child_id
      )

    {:ok, supervisor} = Supervisor.start_link([child_spec], strategy: :one_for_one)
    Process.unlink(supervisor)
    on_exit(fn -> stop_supervisor(supervisor) end)
    publisher = Process.whereis(SecuritySyncPublisher)

    Testing.put(:security_sync_subscribers, %{
      capability_store: %{
        owner: SecuritySyncPublisher,
        supervisor: supervisor,
        child_id: child_id,
        events: [:capability_revoked]
      }
    })

    assert {:ok, _subscription_handle, _bus_pid, _delivery_ref} =
             SecuritySyncPublisher.subscribe(
               publisher,
               :capability_store,
               :capability_revoked
             )

    publisher
  end

  defp stop_supervisor(supervisor) do
    Supervisor.stop(supervisor)
  catch
    :exit, :noproc -> :ok
    :exit, {:noproc, _details} -> :ok
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
    alias Arbor.Signals.AuthorizedChannelsTestClient, as: Channels

    test "security regression (OQ-7): non-member subscriber cannot decrypt channel-encrypted signal" do
      # OQ-7: pre-fix, Bus.maybe_decrypt_channel_signal called
      # Channels.get_key(channel_id, signal.source) — keyed on the SENDER.
      # Anyone subscribed to the topic received decrypted plaintext as long
      # as the SENDER was a member, regardless of whether the SUBSCRIBER was.
      # The fix routes through Channels.decrypt_for_member/3 using the
      # subscriber's executor-issued authorization context. Non-members get
      # __decryption_failed__, not plaintext.
      Bus.reset()

      member = "agent_oq7_member_#{System.unique_integer([:positive])}"
      non_member = "agent_oq7_outsider_#{System.unique_integer([:positive])}"

      {:ok, channel, :server_managed} =
        Channels.create("oq7_channel_#{System.unique_integer([:positive])}", member)

      parent = self()
      handler = fn signal -> send(parent, {:oq7_signal, signal.data}) end

      {:ok, sub_id} =
        Bus.subscribe("channel.test", handler,
          async: false,
          principal_id: non_member,
          auth_context: Channels.auth(non_member)
        )

      assert :ok = Channels.send(channel.id, member, :test, %{"secret" => "oq7_value"})

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

    @tag :security_regression
    test "security regression: an asserted subscriber id is not a decryption credential" do
      Bus.reset()

      member = "agent_oq7_asserted_#{System.unique_integer([:positive])}"
      {:ok, channel, :server_managed} = Channels.create("asserted identity", member)

      parent = self()
      handler = fn signal -> send(parent, {:oq7_asserted, signal.data}) end

      {:ok, sub_id} =
        Bus.subscribe("channel.asserted_identity", handler,
          async: false,
          principal_id: member
        )

      assert :ok =
               Channels.send(channel.id, member, :asserted_identity, %{"secret" => "forged"})

      assert_receive {:oq7_asserted, delivered_data}, 1000
      assert delivered_data == %{__decryption_failed__: true}

      Bus.unsubscribe(sub_id)
    end

    test "subscriber who IS a member receives decrypted plaintext" do
      Bus.reset()

      member = "agent_oq7_member2_#{System.unique_integer([:positive])}"

      {:ok, channel, :server_managed} =
        Channels.create("oq7_channel_pos_#{System.unique_integer([:positive])}", member)

      parent = self()
      handler = fn signal -> send(parent, {:oq7_signal_pos, signal.data}) end

      {:ok, sub_id} =
        Bus.subscribe("channel.member_plaintext", handler,
          async: false,
          principal_id: member,
          auth_context: Channels.auth(member)
        )

      assert :ok =
               Channels.send(channel.id, member, :member_plaintext, %{
                 "secret" => "oq7_member_value"
               })

      assert_receive {:oq7_signal_pos, delivered_data}, 1000

      assert delivered_data["secret"] == "oq7_member_value",
             "Member subscriber must receive decrypted plaintext. Got: #{inspect(delivered_data)}"

      Bus.unsubscribe(sub_id)
    end
  end
end
