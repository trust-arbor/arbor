defmodule Arbor.Security.UnconfiguredSecuritySyncStartSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Security
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Identity.NonceCache
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.TestBootstrap
  alias Arbor.Signals
  alias Arbor.Signals.Config

  @stores [Registry, NonceCache, CapabilityStore]

  @identity_events [
    :identity_registered,
    :identity_deregistered,
    :identity_suspended,
    :identity_resumed,
    :identity_revoked
  ]

  setup do
    original_distributed_signals = Application.get_env(:arbor_security, :distributed_signals)
    signals_snapshot = Config.Testing.snapshot_namespace()

    :ok = Signals.restore_runtime_fixture()
    Application.put_env(:arbor_security, :distributed_signals, true)

    on_exit(fn ->
      Config.Testing.restore_namespace(signals_snapshot)
      restore_env(:distributed_signals, original_distributed_signals)
      :ok = Signals.restore_runtime_fixture()
      TestBootstrap.restore_supervised_tree!()
    end)

    :ok
  end

  test "security regression: stores start local-only when security-sync subscribers are empty" do
    for subscribers <- [:missing, %{}] do
      case subscribers do
        :missing -> Config.Testing.delete(:security_sync_subscribers)
        map -> Config.Testing.put(:security_sync_subscribers, map)
      end

      Application.put_env(:arbor_security, :distributed_signals, true)

      refute Config.security_sync_transport_configured?()
      refute Config.authenticated_security_sync_transport?()
      refute Arbor.Signals.authenticated_security_sync_transport?()
      refute Arbor.Security.Config.distributed_signals_enabled?()

      assert {:ok, _} = restart_security_stores()

      for store <- @stores do
        assert Process.whereis(store)
        assert :sys.get_state(store).signal_sync == nil
      end

      principal = "agent_local_sync_#{System.unique_integer([:positive])}"
      resource = "arbor://test/unconfigured_sync/#{System.unique_integer([:positive])}"

      assert {:ok, _capability} = Security.grant_fixture(principal: principal, resource: resource)

      assert {:ok, :authorized} =
               Security.authorize(principal, resource, nil, verify_identity: false)
    end
  end

  test "security regression: configured sync still fails closed when the owner cannot subscribe" do
    Config.Testing.put(:security_sync_subscribers, %{
      identity_registry: %{
        owner: :arbor_security_sync_impostor,
        events: @identity_events
      }
    })

    Application.put_env(:arbor_security, :distributed_signals, true)
    assert Config.security_sync_transport_configured?()
    refute Config.authenticated_security_sync_transport?()
    refute Arbor.Signals.authenticated_security_sync_transport?()
    assert Arbor.Security.Config.distributed_signals_enabled?()

    registration_token = Registry.test_system_authority_registration_token()
    {:ok, role_specs} = Arbor.Security.Config.signing_key_owner_roles()

    supervisor = Process.whereis(Arbor.Security.Supervisor)
    assert is_pid(supervisor)
    :ok = Supervisor.terminate_child(supervisor, Registry)
    :ok = Supervisor.delete_child(supervisor, Registry)

    registry_opts = [
      system_authority_registration_token: registration_token,
      registration_role_specs:
        Map.take(role_specs, [:system_authority, :scheduler_owner, :trust_grant_owner]),
      defer_initialization: true
    ]

    spec =
      Supervisor.child_spec({Registry, registry_opts},
        id: Registry,
        restart: :temporary
      )

    assert {:ok, registry} =
             Supervisor.start_child(supervisor, spec)

    monitor = Process.monitor(registry)

    assert {:error, :registration_unavailable} =
             Registry.complete_startup(supervisor, registration_token)

    assert_receive {:DOWN, ^monitor, :process, ^registry,
                    {:security_sync_subscription_failed,
                     {:subscription_failed, _topic, :unauthorized}}},
                   1_000

    refute Process.alive?(registry)
    assert Process.whereis(Registry) == nil
  end

  defp restart_security_stores do
    Enum.reduce_while(@stores, {:ok, []}, fn store, {:ok, acc} ->
      _ = Supervisor.terminate_child(Arbor.Security.Supervisor, store)

      case Supervisor.restart_child(Arbor.Security.Supervisor, store) do
        {:ok, pid} -> {:cont, {:ok, [pid | acc]}}
        {:ok, pid, _info} -> {:cont, {:ok, [pid | acc]}}
        {:error, reason} -> {:halt, {:error, {store, reason}}}
      end
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_security, key, value)
end
