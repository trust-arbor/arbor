defmodule Arbor.Monitor.AnomalyForwarderDeliveryTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Monitor.AnomalyForwarder
  alias Arbor.Monitor.Config.Testing

  setup do
    Testing.isolate_namespace()
    Testing.put(:start_ops_room, false)
    Testing.delete(:channel_bridge_module)
    Testing.delete(:agent_directory_module)
    Testing.put(:k1d_test_pid, self())

    {:ok, _pid} = start_supervised(AnomalyForwarder)

    :ok
  end

  test "injected delivery posts Monitor system sender and anomaly text" do
    Testing.put(:channel_bridge_module, __MODULE__.RecordingBridge)
    assert :ok = AnomalyForwarder.set_channel("chan_injected")

    send(AnomalyForwarder, {:signal, anomaly_signal()})
    assert :ok = AnomalyForwarder.set_channel("chan_injected")

    assert_received {:deliver, "chan_injected", "anomaly_forwarder", "Monitor", :system, content}
    assert content =~ "[ANOMALY] warning in beam:"
  end

  test "nil provider skips delivery without crashing" do
    Testing.delete(:channel_bridge_module)
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
      Testing.put(:channel_bridge_module, provider)
      assert :ok = AnomalyForwarder.set_channel("chan_malformed")

      send(AnomalyForwarder, {:signal, anomaly_signal()})
      assert :ok = AnomalyForwarder.set_channel("chan_malformed")
      assert Process.alive?(Process.whereis(AnomalyForwarder))
    end
  end

  test "raising, throwing, or exiting provider does not crash the forwarder" do
    Testing.put(:channel_bridge_module, __MODULE__.RaisingBridge)
    send_and_sync()
    assert Process.alive?(Process.whereis(AnomalyForwarder))

    Testing.put(:channel_bridge_module, __MODULE__.ThrowingBridge)
    send_and_sync()
    assert Process.alive?(Process.whereis(AnomalyForwarder))

    Testing.put(:channel_bridge_module, __MODULE__.ExitingBridge)
    send_and_sync()
    assert Process.alive?(Process.whereis(AnomalyForwarder))
  end

  test "missing callback and non-atom provider skip delivery without crashing" do
    Testing.put(:channel_bridge_module, __MODULE__.EmptyBridge)
    send_and_sync()
    assert Process.alive?(Process.whereis(AnomalyForwarder))

    Testing.put(:channel_bridge_module, "not-a-module")
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

  defmodule RecordingBridge do
    def deliver_channel_message(channel_id, sender_id, sender_name, sender_type, content) do
      send(
        Arbor.Monitor.Config.Testing.get(:k1d_test_pid),
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
