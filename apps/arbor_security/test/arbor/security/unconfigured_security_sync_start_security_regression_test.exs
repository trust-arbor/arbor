defmodule Arbor.Security.UnconfiguredSecuritySyncStartSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Security
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Identity.NonceCache
  alias Arbor.Security.Identity.Registry
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

    Application.put_env(:arbor_security, :distributed_signals, true)

    on_exit(fn ->
      Config.Testing.restore_namespace(signals_snapshot)
      restore_env(:distributed_signals, original_distributed_signals)
      restart_security_stores()
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
      refute Arbor.Security.Config.distributed_signals_enabled?()

      assert {:ok, _} = restart_security_stores()

      for store <- @stores do
        assert Process.whereis(store)
        assert :sys.get_state(store).signal_sync == nil
      end

      principal = "agent_local_sync_#{System.unique_integer([:positive])}"
      resource = "arbor://test/unconfigured_sync/#{System.unique_integer([:positive])}"

      assert {:ok, _capability} = Security.grant(principal: principal, resource: resource)

      assert {:ok, :authorized} =
               Security.authorize(principal, resource, nil, verify_identity: false)
    end
  end

  test "security regression: configured sync still fails closed when the owner cannot subscribe" do
    ensure_signals_bus()

    Config.Testing.put(:security_sync_subscribers, %{
      identity_registry: %{
        owner: :arbor_security_sync_impostor,
        events: @identity_events
      }
    })

    Application.put_env(:arbor_security, :distributed_signals, true)
    assert Config.security_sync_transport_configured?()
    assert Arbor.Security.Config.distributed_signals_enabled?()

    :ok = Supervisor.terminate_child(Arbor.Security.Supervisor, Registry)

    assert {:error,
            {:security_sync_subscription_failed, {:subscription_failed, _, :unauthorized}}} =
             Supervisor.restart_child(Arbor.Security.Supervisor, Registry)
  end

  defp ensure_signals_bus do
    {:ok, _started} = Application.ensure_all_started(:arbor_kernel_runtime)

    case Process.whereis(Arbor.Signals.Bus) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case Supervisor.start_child(Arbor.Signals.Supervisor, {Arbor.Signals.Bus, []}) do
          {:ok, _pid} ->
            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          {:error, :already_present} ->
            {:ok, _} = Supervisor.restart_child(Arbor.Signals.Supervisor, Arbor.Signals.Bus)
            :ok
        end
    end
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
