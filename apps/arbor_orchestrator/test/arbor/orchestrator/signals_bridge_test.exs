defmodule Arbor.Orchestrator.SignalsBridgeTest do
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.SignalsBridge

  describe "SignalsBridge" do
    test "starts and subscribes without crashing" do
      # The bridge should already be started by Application
      # Just verify we can get its pid
      pid = Process.whereis(SignalsBridge)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "handles pipeline_event without crashing" do
      pid = Process.whereis(SignalsBridge)

      event = %{
        type: :pipeline_started,
        graph_id: "test_graph",
        logs_root: "/tmp/test",
        node_count: 5
      }

      # Send event directly to the bridge
      send(pid, {:pipeline_event, event})

      # Give it time to process
      Process.sleep(50)

      # Bridge should still be alive
      assert Process.alive?(pid)
    end

    test "handles multiple event types" do
      pid = Process.whereis(SignalsBridge)

      events = [
        %{type: :pipeline_started, graph_id: "g1", node_count: 3},
        %{type: :stage_started, node_id: "node1"},
        %{type: :stage_completed, node_id: "node1", status: :success, duration_ms: 100},
        %{type: :pipeline_completed, completed_nodes: ["node1"], duration_ms: 150}
      ]

      # Send all events
      Enum.each(events, fn event ->
        send(pid, {:pipeline_event, event})
      end)

      # Give it time to process
      Process.sleep(100)

      # Bridge should still be alive
      assert Process.alive?(pid)
    end

    test "ignores unknown messages" do
      pid = Process.whereis(SignalsBridge)

      # Send random message
      send(pid, :random_message)
      send(pid, {:unknown, "data"})

      # Give it time to process
      Process.sleep(50)

      # Bridge should still be alive
      assert Process.alive?(pid)
    end
  end
end
