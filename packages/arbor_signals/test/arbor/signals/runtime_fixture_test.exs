defmodule Arbor.Signals.RuntimeFixtureTest do
  use ExUnit.Case, async: false

  alias Arbor.Signals

  @children [
    Arbor.Signals.Store,
    Arbor.Signals.TopicKeys,
    Arbor.Signals.Channels,
    Arbor.Signals.SubscriptionRegistry,
    Arbor.Signals.TelemetryBridge,
    Arbor.Signals.Bus,
    Arbor.Signals.Relay
  ]

  setup do
    :ok = Signals.restore_runtime_fixture()
    on_exit(fn -> :ok = Signals.restore_runtime_fixture() end)
    :ok
  end

  test "runtime fixture restoration is idempotent and replaces a missing supervised child" do
    supervisor = Process.whereis(Arbor.Signals.Supervisor)
    assert is_pid(supervisor)

    original = exact_children(supervisor)
    assert Map.keys(original) |> Enum.sort() == Enum.sort(@children)

    assert :ok = Signals.restore_runtime_fixture()
    assert exact_children(supervisor) == original

    removed = Arbor.Signals.Relay
    removed_pid = Map.fetch!(original, removed)
    assert :ok = Supervisor.terminate_child(supervisor, removed)
    assert :ok = Supervisor.delete_child(supervisor, removed)
    refute Process.alive?(removed_pid)
    refute Process.whereis(removed)

    assert :ok = Signals.restore_runtime_fixture()

    restored = exact_children(supervisor)
    assert Map.keys(restored) |> Enum.sort() == Enum.sort(@children)
    refute Map.fetch!(restored, removed) == removed_pid

    for child <- @children -- [removed] do
      assert Map.fetch!(restored, child) == Map.fetch!(original, child)
    end
  end

  defp exact_children(supervisor) do
    owned =
      Map.new(Supervisor.which_children(supervisor), fn {id, pid, _type, _modules} ->
        {id, pid}
      end)

    Map.new(@children, fn child ->
      pid = Map.fetch!(owned, child)
      assert is_pid(pid)
      assert Process.whereis(child) == pid
      assert Process.alive?(pid)
      {child, pid}
    end)
  end
end
