defmodule Arbor.Monitor.ConfigTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Monitor.Config
  alias Arbor.Monitor.Config.Testing

  setup do
    Testing.isolate_namespace()
    :ok
  end

  test "channel-bridge and agent-directory seams default to nil" do
    Testing.delete(:channel_bridge_module)
    Testing.delete(:agent_directory_module)

    assert Config.channel_bridge_module() == nil
    assert Config.agent_directory_module() == nil
  end

  test "channel-bridge and agent-directory seams return configured atoms" do
    Testing.put(:channel_bridge_module, __MODULE__.FakeBridge)
    Testing.put(:agent_directory_module, __MODULE__.FakeDirectory)

    assert Config.channel_bridge_module() == __MODULE__.FakeBridge
    assert Config.agent_directory_module() == __MODULE__.FakeDirectory
  end

  test "test config deep-merges base Monitor keys with the environment override" do
    assert Config.start_children?() == false
    assert Config.signal_emission_enabled?() == false
    assert Config.suppression_window_ms() == :timer.seconds(5)
    assert Config.signal_module() == Arbor.Signals
  end

  test "kernel values are visible through owner getters" do
    Testing.put(:channel_bridge_module, :kernel_only)
    assert Config.channel_bridge_module() == :kernel_only

    Testing.put(:start_children, false)
    assert Config.start_children?() == false
  end

  test "configured nil is distinct from a missing start_children key" do
    Testing.put(:start_children, nil)
    assert Config.start_children?() == nil

    Testing.delete(:start_children)
    assert Config.start_children?() == true
  end

  test "configured nil on a nil-default seam is not treated as missing" do
    Testing.put(:channel_bridge_module, nil)
    assert Config.channel_bridge_module() == nil
  end

  test "namespace snapshot restores missing distinctly from configured nil" do
    Application.delete_env(:arbor_kernel, :monitor)
    assert Testing.snapshot_namespace() == :error

    Testing.restore_namespace({:ok, nil})
    assert Testing.snapshot_namespace() == {:ok, nil}

    Testing.restore_namespace(:error)
    assert Testing.snapshot_namespace() == :error

    Testing.restore_namespace({:ok, [channel_bridge_module: nil]})
    assert Testing.snapshot_namespace() == {:ok, [channel_bridge_module: nil]}
    assert Config.channel_bridge_module() == nil
  end

  test "test namespace mutations preserve map containers" do
    Testing.restore_namespace({:ok, %{channel_bridge_module: :first, untouched: :kept}})
    Testing.put(:channel_bridge_module, :second)

    assert Config.channel_bridge_module() == :second
    assert Testing.get(:channel_bridge_module) == :second
    assert Testing.get(:untouched) == :kept

    Testing.delete(:channel_bridge_module)
    assert Testing.get(:channel_bridge_module, :missing) == :missing
    assert Testing.get(:untouched) == :kept
  end

  test "malformed namespace containers raise through owner getters" do
    Enum.each([nil, [:not_a_keyword], ~D[2026-08-14]], fn malformed ->
      Testing.restore_namespace({:ok, malformed})

      assert_raise ArgumentError, ~r/malformed :arbor_kernel :monitor namespace/, fn ->
        Config.channel_bridge_module()
      end
    end)
  end

  defmodule FakeBridge do
  end

  defmodule FakeDirectory do
  end
end
