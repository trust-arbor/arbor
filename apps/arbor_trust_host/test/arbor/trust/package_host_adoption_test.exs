defmodule Arbor.Trust.PackageHostAdoptionTest do
  use ExUnit.Case, async: false
  @moduletag :fast
  alias Arbor.Trust.Config

  test "passive product composition preserves canonical Trust module and process owners" do
    assert {:ok, _} = Application.ensure_all_started(:arbor_trust_host)
    assert Application.spec(:arbor_trust_host, :mod) in [nil, []]
    assert Application.spec(:arbor_trust_host, :registered) in [nil, []]
    apps = Application.spec(:arbor_trust_host, :applications)

    assert Enum.find_index(apps, &(&1 == :arbor_kernel_runtime)) <
             Enum.find_index(apps, &(&1 == :arbor_trust))

    for module <- [
          Arbor.Trust,
          Arbor.Trust.Application,
          Arbor.Trust.PolicyHost,
          Arbor.Trust.Supervisor,
          Arbor.Trust.ConfirmationTracker,
          Arbor.Trust.CapabilityGrantOwner
        ] do
      assert Application.get_application(module) == :arbor_trust
      refute module in (Application.spec(:arbor_trust_host, :modules) || [])
    end

    for name <- [Arbor.Trust.ApplicationSupervisor, Arbor.Trust.PolicyHost] do
      pid = Process.whereis(name)
      assert is_pid(pid)
      assert :application.get_application(pid) == {:ok, :arbor_trust}
    end
  end

  test "product composition explicitly retains the previous PubSub binding" do
    assert Config.pubsub() == Arbor.Core.PubSub
  end
end
