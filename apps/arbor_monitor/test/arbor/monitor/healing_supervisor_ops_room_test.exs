defmodule Arbor.Monitor.HealingSupervisorOpsRoomTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Monitor.AnomalyForwarder
  alias Arbor.Monitor.HealingSupervisor

  setup do
    originals = %{
      start_ops_room: Application.get_env(:arbor_monitor, :start_ops_room, :unset),
      channel_bridge: Application.get_env(:arbor_monitor, :channel_bridge_module, :unset),
      agent_directory: Application.get_env(:arbor_monitor, :agent_directory_module, :unset),
      test_pid: Application.get_env(:arbor_monitor, :k1d_test_pid, :unset),
      ops_channel: Application.get_env(:arbor_monitor, :k1d_ops_channel_id, :unset)
    }

    Application.put_env(:arbor_monitor, :start_ops_room, false)
    Application.delete_env(:arbor_monitor, :channel_bridge_module)
    Application.delete_env(:arbor_monitor, :agent_directory_module)
    Application.put_env(:arbor_monitor, :k1d_test_pid, self())

    {:ok, _pid} = start_supervised(AnomalyForwarder)

    on_exit(fn ->
      restore(:start_ops_room, originals.start_ops_room)
      restore(:channel_bridge_module, originals.channel_bridge)
      restore(:agent_directory_module, originals.agent_directory)
      restore(:k1d_test_pid, originals.test_pid)
      restore(:k1d_ops_channel_id, originals.ops_channel)
    end)

    :ok
  end

  test "injected lookup plus create binds later delivery to returned channel id" do
    channel_id = "chan_ops_#{System.unique_integer([:positive])}"
    Application.put_env(:arbor_monitor, :k1d_ops_channel_id, channel_id)

    Application.put_env(
      :arbor_monitor,
      :agent_directory_module,
      __MODULE__.DirectoryWithDiagnostician
    )

    Application.put_env(:arbor_monitor, :channel_bridge_module, __MODULE__.RecordingOpsBridge)

    HealingSupervisor.setup_ops_room_fallback()

    assert_received {:create, "ops-room", participants}

    assert %{id: "agent_diag", name: "Diagnostician", type: :agent} in participants

    assert %{id: "anomaly_forwarder", name: "Monitor", type: :system} in participants

    send(AnomalyForwarder, {:signal, anomaly_signal()})
    assert :ok = AnomalyForwarder.set_channel(channel_id)

    assert_received {:deliver, ^channel_id, "anomaly_forwarder", "Monitor", :system, content}
    assert content =~ "[ANOMALY]"
  end

  test "nil providers skip lookup and create" do
    Application.delete_env(:arbor_monitor, :agent_directory_module)
    Application.delete_env(:arbor_monitor, :channel_bridge_module)

    HealingSupervisor.setup_ops_room_fallback()

    refute_received {:create, _, _}
    assert Process.alive?(Process.whereis(AnomalyForwarder))
  end

  test "valid list without diagnostician does not create a room" do
    Application.put_env(
      :arbor_monitor,
      :agent_directory_module,
      __MODULE__.DirectoryWithoutDiagnostician
    )

    Application.put_env(:arbor_monitor, :channel_bridge_module, __MODULE__.RecordingOpsBridge)

    HealingSupervisor.setup_ops_room_fallback()

    refute_received {:create, _, _}
  end

  test "malformed directory results do not create a room" do
    Application.put_env(:arbor_monitor, :channel_bridge_module, __MODULE__.RecordingOpsBridge)

    Application.put_env(
      :arbor_monitor,
      :agent_directory_module,
      __MODULE__.MalformedAtomDirectory
    )

    HealingSupervisor.setup_ops_room_fallback()
    refute_received {:create, _, _}

    Application.put_env(
      :arbor_monitor,
      :agent_directory_module,
      __MODULE__.MalformedIdDirectory
    )

    HealingSupervisor.setup_ops_room_fallback()
    refute_received {:create, _, _}
  end

  test "raising, throwing, or exiting directory does not create a room" do
    Application.put_env(:arbor_monitor, :channel_bridge_module, __MODULE__.RecordingOpsBridge)

    Application.put_env(:arbor_monitor, :agent_directory_module, __MODULE__.RaisingDirectory)
    HealingSupervisor.setup_ops_room_fallback()
    refute_received {:create, _, _}

    Application.put_env(:arbor_monitor, :agent_directory_module, __MODULE__.ThrowingDirectory)
    HealingSupervisor.setup_ops_room_fallback()
    refute_received {:create, _, _}

    Application.put_env(:arbor_monitor, :agent_directory_module, __MODULE__.ExitingDirectory)
    HealingSupervisor.setup_ops_room_fallback()
    refute_received {:create, _, _}
  end

  test "missing list_monitor_agents callback does not create a room" do
    Application.put_env(:arbor_monitor, :agent_directory_module, __MODULE__.EmptyDirectory)
    Application.put_env(:arbor_monitor, :channel_bridge_module, __MODULE__.RecordingOpsBridge)

    HealingSupervisor.setup_ops_room_fallback()

    refute_received {:create, _, _}
  end

  test "ok directory plus raising or malformed create leaves channel unset" do
    Application.put_env(
      :arbor_monitor,
      :agent_directory_module,
      __MODULE__.DirectoryWithDiagnostician
    )

    Application.put_env(
      :arbor_monitor,
      :channel_bridge_module,
      __MODULE__.RaisingCreateBridge
    )

    HealingSupervisor.setup_ops_room_fallback()
    send(AnomalyForwarder, {:signal, anomaly_signal()})
    _ = :sys.get_state(AnomalyForwarder)
    refute_received {:deliver, _, _, _, _, _}

    Application.put_env(
      :arbor_monitor,
      :channel_bridge_module,
      __MODULE__.MalformedCreateBridge
    )

    HealingSupervisor.setup_ops_room_fallback()
    send(AnomalyForwarder, {:signal, anomaly_signal()})
    _ = :sys.get_state(AnomalyForwarder)
    refute_received {:deliver, _, _, _, _, _}
  end

  defp anomaly_signal do
    %{
      type: :anomaly_detected,
      data: %{skill: :beam, severity: :warning, details: %{metric: :reductions}}
    }
  end

  defp restore(key, :unset), do: Application.delete_env(:arbor_monitor, key)
  defp restore(key, value), do: Application.put_env(:arbor_monitor, key, value)

  defmodule DirectoryWithDiagnostician do
    def list_monitor_agents do
      {:ok,
       [
         %{agent_id: "agent_decoy", display_name: "other"},
         %{agent_id: "agent_diag", display_name: "diagnostician"}
       ]}
    end
  end

  defmodule DirectoryWithoutDiagnostician do
    def list_monitor_agents do
      {:ok, [%{agent_id: "agent_x", display_name: "other"}]}
    end
  end

  defmodule MalformedAtomDirectory do
    def list_monitor_agents, do: {:ok, :nope}
  end

  defmodule MalformedIdDirectory do
    def list_monitor_agents, do: {:ok, [%{agent_id: 1, display_name: "diagnostician"}]}
  end

  defmodule RaisingDirectory do
    def list_monitor_agents, do: raise("directory boom")
  end

  defmodule ThrowingDirectory do
    def list_monitor_agents, do: throw(:directory_throw)
  end

  defmodule ExitingDirectory do
    def list_monitor_agents, do: exit(:directory_exit)
  end

  defmodule EmptyDirectory do
  end

  defmodule RecordingOpsBridge do
    def create_ops_room(name, participants) do
      send(Application.get_env(:arbor_monitor, :k1d_test_pid), {:create, name, participants})
      {:ok, Application.get_env(:arbor_monitor, :k1d_ops_channel_id)}
    end

    def deliver_channel_message(channel_id, sender_id, sender_name, sender_type, content) do
      send(
        Application.get_env(:arbor_monitor, :k1d_test_pid),
        {:deliver, channel_id, sender_id, sender_name, sender_type, content}
      )

      :ok
    end
  end

  defmodule RaisingCreateBridge do
    def create_ops_room(_name, _participants), do: raise("create boom")

    def deliver_channel_message(channel_id, sender_id, sender_name, sender_type, content) do
      send(
        Application.get_env(:arbor_monitor, :k1d_test_pid),
        {:deliver, channel_id, sender_id, sender_name, sender_type, content}
      )

      :ok
    end
  end

  defmodule MalformedCreateBridge do
    def create_ops_room(_name, _participants), do: {:ok, :not_an_id}

    def deliver_channel_message(channel_id, sender_id, sender_name, sender_type, content) do
      send(
        Application.get_env(:arbor_monitor, :k1d_test_pid),
        {:deliver, channel_id, sender_id, sender_name, sender_type, content}
      )

      :ok
    end
  end
end
