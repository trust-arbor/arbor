defmodule Arbor.Monitor.ConfigTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Monitor.Config

  setup do
    originals = %{
      channel_bridge: Application.get_env(:arbor_monitor, :channel_bridge_module, :unset),
      agent_directory: Application.get_env(:arbor_monitor, :agent_directory_module, :unset)
    }

    on_exit(fn ->
      restore(:channel_bridge_module, originals.channel_bridge)
      restore(:agent_directory_module, originals.agent_directory)
    end)

    :ok
  end

  test "channel-bridge and agent-directory seams default to nil" do
    Application.delete_env(:arbor_monitor, :channel_bridge_module)
    Application.delete_env(:arbor_monitor, :agent_directory_module)

    assert Config.channel_bridge_module() == nil
    assert Config.agent_directory_module() == nil
  end

  test "channel-bridge and agent-directory seams return configured atoms" do
    Application.put_env(:arbor_monitor, :channel_bridge_module, __MODULE__.FakeBridge)
    Application.put_env(:arbor_monitor, :agent_directory_module, __MODULE__.FakeDirectory)

    assert Config.channel_bridge_module() == __MODULE__.FakeBridge
    assert Config.agent_directory_module() == __MODULE__.FakeDirectory
  end

  defp restore(key, :unset), do: Application.delete_env(:arbor_monitor, key)
  defp restore(key, value), do: Application.put_env(:arbor_monitor, key, value)

  defmodule FakeBridge do
  end

  defmodule FakeDirectory do
  end
end
