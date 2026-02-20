defmodule Arbor.Monitor.AnomalyForwarderTest do
  use ExUnit.Case, async: false

  alias Arbor.Monitor.AnomalyForwarder

  setup do
    Application.put_env(:arbor_monitor, :start_ops_room, false)

    on_exit(fn ->
      Application.delete_env(:arbor_monitor, :start_ops_room)
    end)

    {:ok, pid} = start_supervised(AnomalyForwarder)
    %{forwarder: pid}
  end

  describe "start_link/1" do
    @tag :fast
    test "starts without group_pid" do
      assert Process.whereis(AnomalyForwarder) != nil
    end
  end

  describe "set_group/1" do
    @tag :fast
    test "accepts a group pid", %{forwarder: _forwarder} do
      # Use self() as a mock group
      assert :ok = AnomalyForwarder.set_group(self())
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
      # Should not crash
      Process.sleep(50)
      assert Process.alive?(Process.whereis(AnomalyForwarder))
    end

    @tag :fast
    test "handles cascade_detected signal without group (no crash)" do
      signal = %{
        type: :cascade_detected,
        data: %{anomaly_count: 10}
      }

      send(Process.whereis(AnomalyForwarder), {:signal, signal})
      Process.sleep(50)
      assert Process.alive?(Process.whereis(AnomalyForwarder))
    end

    @tag :fast
    test "handles healing_verified signal without group (no crash)" do
      signal = %{
        type: :healing_verified,
        data: %{fingerprint: "beam:reductions"}
      }

      send(Process.whereis(AnomalyForwarder), {:signal, signal})
      Process.sleep(50)
      assert Process.alive?(Process.whereis(AnomalyForwarder))
    end

    @tag :fast
    test "handles healing_ineffective signal without group (no crash)" do
      signal = %{
        type: :healing_ineffective,
        data: %{fingerprint: "beam:reductions"}
      }

      send(Process.whereis(AnomalyForwarder), {:signal, signal})
      Process.sleep(50)
      assert Process.alive?(Process.whereis(AnomalyForwarder))
    end

    @tag :fast
    test "handles unknown signal types gracefully" do
      signal = %{type: :unknown_signal, data: %{}}
      send(Process.whereis(AnomalyForwarder), {:signal, signal})
      Process.sleep(50)
      assert Process.alive?(Process.whereis(AnomalyForwarder))
    end

    @tag :fast
    test "handles non-signal messages gracefully" do
      send(Process.whereis(AnomalyForwarder), :random_message)
      Process.sleep(50)
      assert Process.alive?(Process.whereis(AnomalyForwarder))
    end
  end

  describe "cascade batching" do
    @tag :fast
    test "flush_cascade_batch message is handled" do
      send(Process.whereis(AnomalyForwarder), :flush_cascade_batch)
      Process.sleep(50)
      assert Process.alive?(Process.whereis(AnomalyForwarder))
    end
  end
end
