defmodule Arbor.Trust.PackageRuntimePortsTest do
  use ExUnit.Case, async: false
  @moduletag :fast
  alias Arbor.Contracts.Trust.Profile

  defmodule InvalidRuntime do
    @behaviour Arbor.Trust.Contracts.RuntimeHost
    def prepare_startup, do: :malformed
    def start_profile, do: :full
    def provider_gate_child_spec(_name, _roots), do: :malformed
    def start_provider_gate_supervisor(_children, _name, _gate), do: :malformed
  end

  defmodule FailedSync do
    @behaviour Arbor.Trust.Contracts.ProfileSync
    def subscribe(_pid), do: {:error, :offline}
    def broadcast(_type, _data), do: {:error, :offline}
  end

  defmodule FailedBroadcast do
    @behaviour Arbor.Trust.Contracts.ProfileSync
    def subscribe(_pid), do: :ok
    def broadcast(_type, _data), do: {:error, :offline}
  end

  setup do
    keys = [:runtime_host, :runtime, :start_children, :profile_store, :profile_sync_transport]
    saved = Map.new(keys, &{&1, Application.fetch_env(:arbor_trust, &1)})
    stop_trust()
    Application.put_env(:arbor_trust, :runtime_host, nil)
    Application.put_env(:arbor_trust, :runtime, start_profile: :full)
    Application.put_env(:arbor_trust, :start_children, false)
    Application.put_env(:arbor_trust, :profile_sync_transport, nil)

    on_exit(fn ->
      stop_trust()

      for {key, value} <- saved do
        case value do
          {:ok, value} -> Application.put_env(:arbor_trust, key, value)
          :error -> Application.delete_env(:arbor_trust, key)
        end
      end

      {:ok, _} = Application.ensure_all_started(:arbor_trust)
    end)

    :ok
  end

  test "configured unavailable or malformed runtime fails before PolicyHost can claim authority" do
    for {provider, reason} <- [
          {__MODULE__.Unavailable, :runtime_host_unavailable},
          {InvalidRuntime, :invalid_runtime_host_response}
        ] do
      Application.put_env(:arbor_trust, :runtime_host, provider)

      assert {:error, {:arbor_trust, {^reason, {Arbor.Trust.Application, :start, _}}}} =
               Application.ensure_all_started(:arbor_trust)

      assert Process.whereis(Arbor.Trust.PolicyHost) == nil
      assert Process.whereis(Arbor.Trust.ApplicationSupervisor) == nil
    end
  end

  test "standalone activation owns the real canonical PolicyHost without a product gate" do
    Application.put_env(:arbor_trust, :runtime, start_profile: :activation_only)
    assert {:ok, _} = Application.ensure_all_started(:arbor_trust)
    pid = Process.whereis(Arbor.Trust.PolicyHost)
    assert is_pid(pid)
    assert :application.get_application(pid) == {:ok, :arbor_trust}
    assert Process.whereis(Arbor.Trust.ProviderGate) == nil
    assert Process.whereis(Arbor.Trust.Supervisor) == nil
    assert Application.get_application(Arbor.Trust.PolicyHost) == :arbor_trust
  end

  test "full startup refuses an absent durable profile store instead of selecting a product backend" do
    Application.put_env(:arbor_trust, :start_children, true)
    Application.delete_env(:arbor_trust, :profile_store)

    assert {:error, {:arbor_trust, {reason, {Arbor.Trust.Application, :start, _}}}} =
             Application.ensure_all_started(:arbor_trust)

    assert inspect(reason) =~ "trust_profile_store_unconfigured"
    refute Process.whereis(Arbor.Trust.Supervisor)
    refute Process.whereis(Arbor.Trust.Store)
  end

  test "configured invalidation transport failure refuses Store startup before cache ownership" do
    Application.put_env(:arbor_trust, :profile_sync_transport, FailedSync)
    previous_trap = Process.flag(:trap_exit, true)

    try do
      assert {:error, {:profile_sync_failed, :offline}} =
               Arbor.Trust.Store.start_link(persistence: :memory)

      assert :ets.whereis(:trust_profile_cache) == :undefined
      refute Process.whereis(Arbor.Trust.Store)
    after
      Process.flag(:trap_exit, previous_trap)
    end
  end

  test "post-commit transport failure is observable without undoing an acknowledged local write" do
    Application.put_env(:arbor_trust, :profile_sync_transport, FailedBroadcast)
    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:arbor, :trust, :profile_sync, :failed],
        fn event, measurements, metadata, _ -> send(owner, {event, measurements, metadata}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    start_supervised!({Arbor.Trust.Store, [persistence: :memory]})
    assert {:ok, profile} = Profile.new("agent_sync_failure")
    assert :ok = Arbor.Trust.Store.store_profile(profile)
    assert {:ok, ^profile} = Arbor.Trust.Store.get_profile(profile.agent_id)

    assert_receive {[:arbor, :trust, :profile_sync, :failed], %{count: 1},
                    %{type: :profile_updated, reason: {:profile_sync_failed, :offline}}}
  end

  test "canonical application closure contains no product runtime or concrete transport" do
    apps = Application.spec(:arbor_trust, :applications)
    assert :arbor_kernel in apps
    assert :arbor_support in apps

    for app <- [
          :arbor_kernel_runtime,
          :arbor_security,
          :arbor_trust_host,
          :arbor_signals,
          :arbor_persistence_host,
          :arbor_persistence_sql,
          :phoenix_pubsub
        ] do
      refute app in apps
    end

    assert Application.spec(:arbor_trust, :mod) == {Arbor.Trust.Application, []}
  end

  defp stop_trust do
    Application.stop(:arbor_trust)
    Arbor.Trust.PolicyHost.release_claim()
  end
end
