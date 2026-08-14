defmodule Arbor.Monitor.ConfigTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Monitor.Config
  alias Arbor.Monitor.Config.Testing

  @legacy_keys [
    :channel_bridge_module,
    :agent_directory_module,
    :start_children,
    :signal_emission_enabled
  ]

  setup do
    Testing.isolate_namespace()
    legacy = Map.new(@legacy_keys, &{&1, Testing.snapshot_legacy_key(&1)})

    on_exit(fn ->
      Enum.each(legacy, fn {key, snapshot} -> Testing.restore_legacy_key(key, snapshot) end)
    end)

    :ok
  end

  test "channel-bridge and agent-directory seams default to nil" do
    Testing.delete(:channel_bridge_module)
    Testing.delete(:agent_directory_module)
    Testing.delete_legacy(:channel_bridge_module)
    Testing.delete_legacy(:agent_directory_module)

    assert Config.channel_bridge_module() == nil
    assert Config.agent_directory_module() == nil
  end

  test "channel-bridge and agent-directory seams return configured atoms" do
    Testing.delete_legacy(:channel_bridge_module)
    Testing.delete_legacy(:agent_directory_module)
    Testing.put(:channel_bridge_module, __MODULE__.FakeBridge)
    Testing.put(:agent_directory_module, __MODULE__.FakeDirectory)

    assert Config.channel_bridge_module() == __MODULE__.FakeBridge
    assert Config.agent_directory_module() == __MODULE__.FakeDirectory
  end

  test "test config deep-merges base Monitor keys with the environment override" do
    Testing.delete_legacy(:start_children)
    Testing.delete_legacy(:signal_emission_enabled)

    assert Config.start_children?() == false
    assert Config.signal_emission_enabled?() == false
    assert Config.suppression_window_ms() == :timer.seconds(5)
    assert Config.signal_module() == Arbor.Signals
  end

  test "new-only kernel values win through owner getters" do
    Testing.delete_legacy(:channel_bridge_module)
    Testing.put(:channel_bridge_module, :kernel_only)
    assert Config.channel_bridge_module() == :kernel_only

    Testing.delete_legacy(:start_children)
    Testing.put(:start_children, false)
    assert Config.start_children?() == false
  end

  test "legacy-only values win through owner getters" do
    Testing.delete(:channel_bridge_module)
    Testing.put_legacy(:channel_bridge_module, :legacy_only)
    assert Config.channel_bridge_module() == :legacy_only

    Testing.delete(:start_children)
    Testing.put_legacy(:start_children, false)
    assert Config.start_children?() == false
  end

  test "equal dual values are admitted through owner getters" do
    Testing.put(:channel_bridge_module, :same)
    Testing.put_legacy(:channel_bridge_module, :same)
    assert Config.channel_bridge_module() == :same

    Testing.put(:start_children, false)
    Testing.put_legacy(:start_children, false)
    assert Config.start_children?() == false
  end

  test "unequal dual values raise through owner getters" do
    Testing.put(:channel_bridge_module, :kernel_value)
    Testing.put_legacy(:channel_bridge_module, :legacy_value)

    assert_raise ArgumentError, ~r/rejects unequal dual values/, fn ->
      Config.channel_bridge_module()
    end

    Testing.put(:start_children, true)
    Testing.put_legacy(:start_children, false)

    assert_raise ArgumentError, ~r/rejects unequal dual values/, fn ->
      Config.start_children?()
    end
  end

  test "configured nil is distinct from a missing start_children key" do
    Testing.delete_legacy(:start_children)
    Testing.put(:start_children, nil)
    assert Config.start_children?() == nil

    Testing.delete(:start_children)
    Testing.delete_legacy(:start_children)
    assert Config.start_children?() == true
  end

  test "configured nil on a nil-default seam is not treated as missing" do
    Testing.delete_legacy(:channel_bridge_module)
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

    assert Testing.get(:channel_bridge_module) == :second
    assert Testing.get(:untouched) == :kept

    Testing.delete(:channel_bridge_module)
    assert Testing.get(:channel_bridge_module, :missing) == :missing
    assert Testing.get(:untouched) == :kept
  end

  test "only Monitor.Config names ConfigCompat in production lib" do
    root = find_root(__DIR__)
    files = Path.wildcard(Path.join(root, "apps/arbor_monitor/lib/**/*.ex"))
    assert files != []

    named =
      files
      |> Enum.filter(fn path -> File.read!(path) =~ "Arbor.Kernel.ConfigCompat" end)
      |> Enum.map(&Path.relative_to(&1, root))

    assert named == ["apps/arbor_monitor/lib/arbor/monitor/config.ex"]
  end

  defp find_root(dir) do
    cond do
      File.exists?(Path.join([dir, "apps", "arbor_contracts", "mix.exs"])) ->
        dir

      Path.dirname(dir) == dir ->
        flunk("umbrella root not found from #{__DIR__}")

      true ->
        find_root(Path.dirname(dir))
    end
  end

  defmodule FakeBridge do
  end

  defmodule FakeDirectory do
  end
end
