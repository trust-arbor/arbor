defmodule Arbor.Security.SignalSyncUndecryptableDeliverySecurityRegressionTest do
  @moduledoc """
  Security regression for the consumer side of kernel-runtime FINDING-002.

  Topic keys are node-local, so a peer's encrypted security-sync signal cannot
  be decrypted here and the Bus delivers it as `%{__decryption_failed__: true}`.
  The consumers used to read that marker as ordinary data (an empty revocation
  list, a nil agent_id, an empty nonce) and silently applied nothing, so a lost
  revocation left no trace. Each consumer must reject the delivery and surface it.
  """

  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  import ExUnit.CaptureLog

  alias Arbor.Security
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Identity.NonceCache
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.SignalSync
  alias Arbor.Signals

  @peer :peer@undecryptable_security_sync
  @rejected_event [:arbor, :security, :signal_sync, :rejected]

  setup do
    assert :ok = Signals.restore_runtime_fixture()

    test_pid = self()
    handler_id = "signal-sync-undecryptable-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(handler_id, @rejected_event, &__MODULE__.forward_event/4, test_pid)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  @doc false
  def forward_event(_event, measurements, metadata, test_pid) do
    send(test_pid, {:signal_sync_rejected, measurements, metadata})
  end

  test "security regression: CapabilityStore rejects and surfaces an undecryptable revocation" do
    establish_signal_sync(CapabilityStore, :capability_store, [:capability_revoked])

    principal = "agent_undecryptable_sync_#{System.unique_integer([:positive])}"
    resource = "arbor://test/undecryptable_sync/#{System.unique_integer([:positive])}"

    assert {:ok, capability} = Security.grant_fixture(principal: principal, resource: resource)

    assert {:ok, :authorized} =
             Security.authorize(principal, resource, nil, verify_identity: false)

    signal =
      peer_encrypted_signal(:capability_revoked, %{
        capability_ids: [capability.id],
        origin_node: Atom.to_string(@peer)
      })

    log =
      capture_log(fn ->
        assert :ok = Signals.receive_relay_batch_fixture([signal], @peer)

        assert_receive {:signal_sync_rejected, %{count: 1},
                        %{
                          role: :capability_store,
                          type: :capability_revoked,
                          origin_node: @peer,
                          reason: :decryption_failed
                        }},
                       2_000
      end)

    assert log =~ "Rejected undecryptable security-sync delivery"

    # The marker was not applied as data. The revocation itself is lost on
    # this node: no runtime resync path exists, so the fix surfaces the loss.
    assert {:ok, :authorized} =
             Security.authorize(principal, resource, nil, verify_identity: false)
  end

  test "security regression: identity Registry rejects and surfaces an undecryptable suspension" do
    establish_signal_sync(Registry, :identity_registry, [:identity_suspended])

    assert {:ok, identity} =
             Security.generate_identity(
               name: "undecryptable-sync-#{System.unique_integer([:positive])}"
             )

    assert :ok = Security.register_identity_fixture(identity)
    assert {:ok, :active} = Security.identity_status(identity.agent_id)

    signal =
      peer_encrypted_signal(:identity_suspended, %{
        agent_id: identity.agent_id,
        origin_node: Atom.to_string(@peer)
      })

    log =
      capture_log(fn ->
        assert :ok = Signals.receive_relay_batch_fixture([signal], @peer)

        assert_receive {:signal_sync_rejected, %{count: 1},
                        %{
                          role: :identity_registry,
                          type: :identity_suspended,
                          origin_node: @peer,
                          reason: :decryption_failed
                        }},
                       2_000
      end)

    assert log =~ "Rejected undecryptable security-sync delivery"
    assert {:ok, :active} = Security.identity_status(identity.agent_id)
  end

  test "security regression: NonceCache rejects and surfaces an undecryptable nonce_seen" do
    establish_signal_sync(NonceCache, :nonce_cache, [:nonce_seen])

    nonce = :crypto.strong_rand_bytes(16)

    # NonceCache emits its type as the string "nonce_seen", which misses the
    # Signals portable-sync exemption, so a peer's nonce_seen is encrypted under
    # that peer's node-local topic key. Model exactly that producer.
    signal =
      peer_encrypted_signal("nonce_seen", %{
        nonce_hex: Base.encode16(nonce, case: :lower),
        expiry: System.system_time(:second) + 300,
        origin_node: Atom.to_string(@peer)
      })

    log =
      capture_log(fn ->
        assert :ok = Signals.receive_relay_batch_fixture([signal], @peer)

        assert_receive {:signal_sync_rejected, %{count: 1},
                        %{
                          role: :nonce_cache,
                          type: "nonce_seen",
                          origin_node: @peer,
                          reason: :decryption_failed
                        }},
                       2_000
      end)

    assert log =~ "Rejected undecryptable security-sync delivery"

    # The peer's nonce was not recorded from the undecryptable payload.
    assert :ok = NonceCache.check_and_record(nonce, 300)
  end

  # A peer encrypts restricted payloads with its own node-local topic key, so
  # this node's TopicKeys cannot decrypt them. Encrypt a genuine payload under
  # an independent key in the wire shape the Bus relays.
  defp peer_encrypted_signal(type, data) do
    peer_topic_key = :crypto.strong_rand_bytes(32)
    {ciphertext, iv, tag} = Security.encrypt(Jason.encode!(data), peer_topic_key)

    Signals.build_signal_fixture(:security, type, %{
      __encrypted__: true,
      payload: %{ciphertext: ciphertext, iv: iv, tag: tag, key_version: 1}
    })
  end

  # Establish the store's real security-sync subscription without restarting
  # the shared, named store. SignalSync.establish/3 runs inside the store
  # process, exactly as the store's own startup does, so the Bus pins that
  # process as the subscription owner and the delivery ref lands in the
  # store's private custody. Deliveries then take the production path.
  defp establish_signal_sync(store, role, events) do
    if is_nil(:sys.get_state(store).signal_sync) do
      :sys.replace_state(store, fn state ->
        {:ok, %SignalSync{} = sync} = SignalSync.establish(role, events, true)
        %{state | signal_sync: sync}
      end)

      on_exit(fn ->
        :sys.replace_state(store, fn state ->
          :ok = SignalSync.release(state.signal_sync)
          %{state | signal_sync: nil}
        end)
      end)
    end

    :ok
  end
end
