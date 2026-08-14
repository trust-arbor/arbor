defmodule Arbor.Monitor.AnomalyForwarderDeliveryTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Monitor.AnomalyForwarder

  setup do
    originals = %{
      start_ops_room: Application.get_env(:arbor_monitor, :start_ops_room, :unset),
      channel_bridge: Application.get_env(:arbor_monitor, :channel_bridge_module, :unset),
      agent_directory: Application.get_env(:arbor_monitor, :agent_directory_module, :unset),
      test_pid: Application.get_env(:arbor_monitor, :k1d_test_pid, :unset)
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
    end)

    :ok
  end

  test "injected delivery posts Monitor system sender and anomaly text" do
    Application.put_env(:arbor_monitor, :channel_bridge_module, __MODULE__.RecordingBridge)
    assert :ok = AnomalyForwarder.set_channel("chan_injected")

    send(AnomalyForwarder, {:signal, anomaly_signal()})
    assert :ok = AnomalyForwarder.set_channel("chan_injected")

    assert_received {:deliver, "chan_injected", "anomaly_forwarder", "Monitor", :system, content}
    assert content =~ "[ANOMALY] warning in beam:"
  end

  test "nil provider skips delivery without crashing" do
    Application.delete_env(:arbor_monitor, :channel_bridge_module)
    assert :ok = AnomalyForwarder.set_channel("chan_nil")

    send(AnomalyForwarder, {:signal, anomaly_signal()})
    assert :ok = AnomalyForwarder.set_channel("chan_nil")

    refute_received {:deliver, _, _, _, _, _}
    assert Process.alive?(Process.whereis(AnomalyForwarder))
  end

  test "malformed success and unexpected errors are not treated as success" do
    for provider <- [
          __MODULE__.MalformedMapBridge,
          __MODULE__.BlockedAtomBridge,
          __MODULE__.BoomErrorBridge
        ] do
      Application.put_env(:arbor_monitor, :channel_bridge_module, provider)
      assert :ok = AnomalyForwarder.set_channel("chan_malformed")

      send(AnomalyForwarder, {:signal, anomaly_signal()})
      assert :ok = AnomalyForwarder.set_channel("chan_malformed")
      assert Process.alive?(Process.whereis(AnomalyForwarder))
    end
  end

  test "raising, throwing, or exiting provider does not crash the forwarder" do
    Application.put_env(:arbor_monitor, :channel_bridge_module, __MODULE__.RaisingBridge)
    send_and_sync()
    assert Process.alive?(Process.whereis(AnomalyForwarder))

    Application.put_env(:arbor_monitor, :channel_bridge_module, __MODULE__.ThrowingBridge)
    send_and_sync()
    assert Process.alive?(Process.whereis(AnomalyForwarder))

    Application.put_env(:arbor_monitor, :channel_bridge_module, __MODULE__.ExitingBridge)
    send_and_sync()
    assert Process.alive?(Process.whereis(AnomalyForwarder))
  end

  test "missing callback and non-atom provider skip delivery without crashing" do
    Application.put_env(:arbor_monitor, :channel_bridge_module, __MODULE__.EmptyBridge)
    send_and_sync()
    assert Process.alive?(Process.whereis(AnomalyForwarder))

    Application.put_env(:arbor_monitor, :channel_bridge_module, "not-a-module")
    send_and_sync()
    assert Process.alive?(Process.whereis(AnomalyForwarder))
  end

  defp send_and_sync do
    assert :ok = AnomalyForwarder.set_channel("chan_sync")
    send(AnomalyForwarder, {:signal, anomaly_signal()})
    assert :ok = AnomalyForwarder.set_channel("chan_sync")
  end

  defp anomaly_signal do
    %{
      type: :anomaly_detected,
      data: %{skill: :beam, severity: :warning, details: %{metric: :reductions}}
    }
  end

  defp restore(key, :unset), do: Application.delete_env(:arbor_monitor, key)
  defp restore(key, value), do: Application.put_env(:arbor_monitor, key, value)

  defmodule RecordingBridge do
    def deliver_channel_message(channel_id, sender_id, sender_name, sender_type, content) do
      send(
        Application.get_env(:arbor_monitor, :k1d_test_pid),
        {:deliver, channel_id, sender_id, sender_name, sender_type, content}
      )

      :ok
    end
  end

  defmodule MalformedMapBridge do
    def deliver_channel_message(_channel_id, _sender_id, _sender_name, _sender_type, _content) do
      {:ok, %{id: "msg"}}
    end
  end

  defmodule BlockedAtomBridge do
    def deliver_channel_message(_channel_id, _sender_id, _sender_name, _sender_type, _content) do
      :blocked
    end
  end

  defmodule BoomErrorBridge do
    def deliver_channel_message(_channel_id, _sender_id, _sender_name, _sender_type, _content) do
      {:error, "boom"}
    end
  end

  defmodule RaisingBridge do
    def deliver_channel_message(_channel_id, _sender_id, _sender_name, _sender_type, _content) do
      raise "provider boom"
    end
  end

  defmodule ThrowingBridge do
    def deliver_channel_message(_channel_id, _sender_id, _sender_name, _sender_type, _content) do
      throw(:provider_throw)
    end
  end

  defmodule ExitingBridge do
    def deliver_channel_message(_channel_id, _sender_id, _sender_name, _sender_type, _content) do
      exit(:provider_exit)
    end
  end

  defmodule EmptyBridge do
  end
end
