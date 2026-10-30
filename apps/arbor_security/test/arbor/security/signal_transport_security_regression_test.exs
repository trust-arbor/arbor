defmodule Arbor.Security.SignalTransportSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Security
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Config, as: SecurityConfig
  alias Arbor.Security.Identity.NonceCache
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.SignalSync
  alias Arbor.Security.TestBootstrap
  alias Arbor.Signals
  alias Arbor.Signals.Config, as: SignalsConfig

  setup do
    security_snapshot =
      Map.new([:signal_transport, :distributed_signals], fn key ->
        {key, Application.fetch_env(:arbor_capabilities, key)}
      end)

    signals_snapshot = SignalsConfig.Testing.snapshot_namespace()

    on_exit(fn ->
      Enum.each(security_snapshot, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_capabilities, key, value)
        {key, :error} -> Application.delete_env(:arbor_capabilities, key)
      end)

      SignalsConfig.Testing.restore_namespace(signals_snapshot)
      :ok = Signals.restore_runtime_fixture()
      TestBootstrap.restore_supervised_tree!()
    end)

    :ok = Signals.restore_runtime_fixture()
    Application.put_env(:arbor_capabilities, :distributed_signals, true)
    assert Signals.security_sync_transport_configured?()
    :ok
  end

  test "security regression: explicit nil transport is local-only despite configured Signals" do
    Application.put_env(:arbor_capabilities, :signal_transport, nil)

    refute SecurityConfig.distributed_signals_enabled?()

    assert {:ok, nil} =
             SignalSync.establish(:capability_store, [:capability_revoked], true)
  end

  test "security regression: a configured unavailable provider cannot use ambient Signals" do
    Application.put_env(
      :arbor_capabilities,
      :signal_transport,
      Arbor.Security.SignalTransportSecurityRegressionTest.UnavailableProvider
    )

    assert SecurityConfig.distributed_signals_enabled?()

    # Run the existing public subscription boundary in its actual canonical
    # owner. On the predecessor this really subscribes through ambient Signals;
    # a test-process :unauthorized refusal would not prove the missing seam.
    test_pid = self()
    token = make_ref()

    :sys.replace_state(CapabilityStore, fn state ->
      :ok = SignalSync.release(state.signal_sync)

      result =
        case SignalSync.establish(:capability_store, [:capability_revoked], true) do
          {:ok, %SignalSync{} = sync} ->
            :ok = SignalSync.release(sync)
            :unexpected_ambient_signals_subscription

          other ->
            other
        end

      send(test_pid, {token, result})
      %{state | signal_sync: nil}
    end)

    assert_receive {^token, {:error, :security_sync_provider_unavailable}}
  end

  test "security regression: nil transport starts all stores locally without weakening replay" do
    Application.put_env(:arbor_capabilities, :signal_transport, nil)

    for store <- [Registry, NonceCache, CapabilityStore] do
      assert :ok = Supervisor.terminate_child(Arbor.Security.Supervisor, store)
      assert {:ok, pid} = Supervisor.restart_child(Arbor.Security.Supervisor, store)
      assert is_pid(pid)
      assert :sys.get_state(store).signal_sync == nil
    end

    principal = "agent_local_transport_#{System.unique_integer([:positive])}"
    resource = "arbor://test/local_transport/#{System.unique_integer([:positive])}"

    assert {:ok, _capability} = Security.grant_fixture(principal: principal, resource: resource)

    assert {:ok, :authorized} =
             Security.authorize(principal, resource, nil, verify_identity: false)

    nonce = :crypto.strong_rand_bytes(16)
    assert :ok = NonceCache.check_and_record(nonce, 300)
    assert {:error, :replayed_nonce} = NonceCache.check_and_record(nonce, 300)
  end
end
