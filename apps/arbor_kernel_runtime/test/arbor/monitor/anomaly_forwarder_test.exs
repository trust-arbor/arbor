defmodule Arbor.Monitor.AnomalyForwarderTest do
  use ExUnit.Case, async: false

  alias Arbor.Monitor.AnomalyForwarder
  alias Arbor.Monitor.Config.Testing

  setup do
    Testing.isolate_namespace()
    Testing.put(:start_ops_room, false)
    Testing.delete(:channel_bridge_module)
    Testing.delete(:agent_directory_module)

    {:ok, pid} = start_supervised(AnomalyForwarder)
    %{forwarder: pid}
  end

  defp sync_forwarder do
    assert :ok = AnomalyForwarder.set_channel("ops-room")
  end

  describe "start_link/1" do
    @tag :fast
    test "starts without channel" do
      assert Process.whereis(AnomalyForwarder) != nil
    end
  end

  describe "set_channel/1" do
    @tag :fast
    test "accepts a channel id", %{forwarder: _forwarder} do
      assert :ok = AnomalyForwarder.set_channel("ops-room")
    end
  end

  describe "signal handling" do
    @tag :fast
    test "handles anomaly_detected signal without group (no crash)" do
      signal = %{
        type: :anomaly_detected,
        data: %{skill: :beam, severity: :warning, details: %{metric: :reductions}}
      }

      send(Process.whereis(AnomalyForwarder), {:signal, signal})
      sync_forwarder()
      assert Process.alive?(Process.whereis(AnomalyForwarder))
    end

    @tag :fast
    test "handles cascade_detected signal without group (no crash)" do
      signal = %{
        type: :cascade_detected,
        data: %{anomaly_count: 10}
      }

      send(Process.whereis(AnomalyForwarder), {:signal, signal})
      sync_forwarder()
      assert Process.alive?(Process.whereis(AnomalyForwarder))
    end

    @tag :fast
    test "handles healing_verified signal without group (no crash)" do
      signal = %{
        type: :healing_verified,
        data: %{fingerprint: "beam:reductions"}
      }

      send(Process.whereis(AnomalyForwarder), {:signal, signal})
      sync_forwarder()
      assert Process.alive?(Process.whereis(AnomalyForwarder))
    end

    @tag :fast
    test "handles healing_ineffective signal without group (no crash)" do
      signal = %{
        type: :healing_ineffective,
        data: %{fingerprint: "beam:reductions"}
      }

      send(Process.whereis(AnomalyForwarder), {:signal, signal})
      sync_forwarder()
      assert Process.alive?(Process.whereis(AnomalyForwarder))
    end

    @tag :fast
    test "handles unknown signal types gracefully" do
      signal = %{type: :unknown_signal, data: %{}}
      send(Process.whereis(AnomalyForwarder), {:signal, signal})
      sync_forwarder()
      assert Process.alive?(Process.whereis(AnomalyForwarder))
    end

    @tag :fast
    test "handles non-signal messages gracefully" do
      send(Process.whereis(AnomalyForwarder), :random_message)
      sync_forwarder()
      assert Process.alive?(Process.whereis(AnomalyForwarder))
    end
  end

  describe "cascade batching" do
    @tag :fast
    test "flush_cascade_batch message is handled" do
      send(Process.whereis(AnomalyForwarder), :flush_cascade_batch)
      sync_forwarder()
      assert Process.alive?(Process.whereis(AnomalyForwarder))
    end
  end
end
