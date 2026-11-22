defmodule Arbor.Orchestrator.RuntimeFixtureStartupSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Signals
  alias Arbor.Signals.Bus
  alias Arbor.Signals.Config, as: SignalsConfig
  alias Arbor.Trust.Host.ProfileSync, as: HostProfileSync
  alias Arbor.Trust.Store

  @moduletag :fast
  @moduletag :security_regression

  test "security regression: canonical Signals startup precedes Trust profile subscriptions" do
    assert SignalsConfig.supervision_root() == {:application, :arbor_kernel_runtime}
    assert SignalsConfig.supervision_path() == [Arbor.Signals.Application]
    assert SignalsConfig.restricted_topics() == [:security, :identity]
    assert Application.spec(:arbor_kernel_runtime, :mod) == {Arbor.KernelRuntime.Application, []}
    assert :arbor_signals in Application.spec(:arbor_kernel_runtime, :included_applications)
    assert Application.get_application(Arbor.Signals.Application) == :arbor_signals
    assert Application.get_application(Bus) == :arbor_signals

    runtime_root = registered!(Arbor.KernelRuntime.Supervisor)
    signals_root = registered!(Arbor.Signals.Supervisor)
    bus = registered!(Bus)
    assert_child!(runtime_root, Arbor.Signals.Application, signals_root, :supervisor)
    assert_child!(signals_root, Bus, bus, :worker)

    # Signals is an included library tree. Its processes retain the actual
    # KernelRuntime application owner, while their code belongs to Signals.
    assert :application.get_application(runtime_root) == {:ok, :arbor_kernel_runtime}
    assert :application.get_application(signals_root) == {:ok, :arbor_kernel_runtime}
    assert :application.get_application(bus) == {:ok, :arbor_kernel_runtime}

    assert Application.fetch_env!(:arbor_trust, :profile_sync_transport) == HostProfileSync
    assert Application.get_application(HostProfileSync) == :arbor_trust_host
    assert Application.spec(:arbor_trust, :mod) == {Arbor.Trust.Application, []}
    assert Application.get_application(Arbor.Trust.Supervisor) == :arbor_trust
    assert Application.get_application(Store) == :arbor_trust

    trust_application = registered!(Arbor.Trust.ApplicationSupervisor)
    trust_root = registered!(Arbor.Trust.Supervisor)
    store = registered!(Store)
    assert_child!(trust_application, Arbor.Trust.Supervisor, trust_root, :supervisor)
    assert_child!(trust_root, Store, store, :worker)
    assert :application.get_application(trust_application) == {:ok, :arbor_trust}
    assert :application.get_application(trust_root) == {:ok, :arbor_trust}
    assert :application.get_application(store) == {:ok, :arbor_trust}

    observer = fn _signal -> :ok end
    assert {:ok, handle} = Signals.subscribe("trust.profile_updated", observer)

    try do
      # The successful ordinary subscription makes the protected-topic denial
      # nonvacuous: it uses the same live, canonically owned Bus.
      assert {:error, :unauthorized} = Signals.subscribe("security.*", observer)
      assert Process.whereis(Bus) == bus
      assert Process.whereis(Store) == store
      assert_child!(signals_root, Bus, bus, :worker)
      assert_child!(trust_root, Store, store, :worker)
    after
      # Subscription custody belongs to this caller. on_exit runs in another
      # process, so cleanup must remain here; owner death also retires it.
      assert :ok = Signals.unsubscribe(handle)
    end
  end

  defp registered!(name) do
    pid = Process.whereis(name)
    assert is_pid(pid)
    assert Process.alive?(pid)
    pid
  end

  defp assert_child!(supervisor, child_id, pid, type) do
    assert {^child_id, ^pid, ^type, _modules} =
             List.keyfind(Supervisor.which_children(supervisor), child_id, 0)
  end
end
