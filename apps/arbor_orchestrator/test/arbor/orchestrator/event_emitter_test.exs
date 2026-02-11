defmodule Arbor.Orchestrator.EventEmitterTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.EventEmitter

  describe "subscribe/1" do
    test "subscribes to :all events by default" do
      assert {:ok, _} = EventEmitter.subscribe()
    end

    test "subscribes to a specific pipeline ID" do
      assert {:ok, _} = EventEmitter.subscribe("run-123")
    end
  end

  describe "emit/3" do
    test "delivers event to :all subscribers" do
      EventEmitter.subscribe(:all)
      EventEmitter.emit(:all, %{type: :pipeline_started, graph_id: "test"})
      assert_receive {:pipeline_event, %{type: :pipeline_started, graph_id: "test"}}
    end

    test "delivers event to pipeline-specific subscribers" do
      EventEmitter.subscribe("run-abc")
      EventEmitter.emit("run-abc", %{type: :stage_started, node_id: "step1"})
      assert_receive {:pipeline_event, %{type: :stage_started, node_id: "step1"}}
    end

    test ":all subscribers receive events from any pipeline" do
      EventEmitter.subscribe(:all)
      EventEmitter.emit("run-xyz", %{type: :stage_completed, node_id: "s1", status: :success})
      assert_receive {:pipeline_event, %{type: :stage_completed}}
    end

    test "pipeline-specific subscriber does not receive other pipeline events" do
      EventEmitter.subscribe("run-a")
      EventEmitter.emit("run-b", %{type: :stage_started, node_id: "step1"})
      refute_receive {:pipeline_event, _}
    end

    test "backward-compatible :on_event callback is invoked" do
      parent = self()
      callback = fn event -> send(parent, {:callback_event, event}) end
      EventEmitter.emit(:all, %{type: :pipeline_started}, on_event: callback)
      assert_receive {:callback_event, %{type: :pipeline_started}}
    end

    test "no crash when no subscribers exist" do
      assert :ok = EventEmitter.emit("orphan-run", %{type: :stage_started, node_id: "x"})
    end
  end

  describe "unsubscribe/1" do
    test "stops receiving events after unsubscribe" do
      EventEmitter.subscribe("run-unsub")
      EventEmitter.unsubscribe("run-unsub")
      EventEmitter.emit("run-unsub", %{type: :stage_started, node_id: "step1"})
      refute_receive {:pipeline_event, _}
    end
  end
end
