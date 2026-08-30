defmodule Arbor.Orchestrator.EventsTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Orchestrator.Events
  alias Arbor.Persistence.EventLog.ETS

  setup do
    # Durable-first Historian writes: isolated authoritative ETS plus a separate
    # hot projection. read_run_events observes the durable authority.
    suffix = System.unique_integer([:positive])
    # credo:disable-for-lines:2 Credo.Check.Security.UnsafeAtomConversion
    durable = :"orchestrator_events_durable_#{suffix}"
    hot = :"orchestrator_events_hot_#{suffix}"

    start_supervised!({ETS, name: durable}, id: durable)
    start_supervised!({ETS, name: hot, mode: :projection}, id: hot)

    originals = %{
      event_log_name: Application.fetch_env(:arbor_orchestrator, :event_log_name),
      event_log_backend: Application.fetch_env(:arbor_orchestrator, :event_log_backend),
      durable: Application.fetch_env(:arbor_historian, :durable_event_log_target),
      hot: Application.fetch_env(:arbor_historian, :hot_event_log_target)
    }

    Application.put_env(:arbor_orchestrator, :event_log_name, durable)
    Application.put_env(:arbor_orchestrator, :event_log_backend, ETS)
    configure_historian_target(:durable_event_log_target, durable)
    configure_historian_target(:hot_event_log_target, hot)

    Arbor.Signals.Config.Testing.isolate_namespace()
    Arbor.Signals.Config.Testing.put(:durable_sink_module, Arbor.Historian)

    on_exit(fn ->
      restore_env(:arbor_orchestrator, :event_log_name, originals.event_log_name)
      restore_env(:arbor_orchestrator, :event_log_backend, originals.event_log_backend)
      restore_env(:arbor_historian, :durable_event_log_target, originals.durable)
      restore_env(:arbor_historian, :hot_event_log_target, originals.hot)
    end)

    %{durable: durable, hot: hot}
  end

  describe "stream_id/1" do
    test "builds stream ID from run_id" do
      assert Events.stream_id("run_Test_nonode@nohost_20260310_a1b2c3d4") ==
               "orchestrator:pipeline:run_Test_nonode@nohost_20260310_a1b2c3d4"
    end

    test "handles nil run_id" do
      assert Events.stream_id(nil) == "orchestrator:pipeline:unknown"
    end
  end

  describe "dual_emit/2" do
    test "persists pipeline_started event to EventLog" do
      run_id = "run_test_#{System.unique_integer([:positive])}"

      event = %{
        type: :pipeline_started,
        graph_id: "TestGraph",
        run_id: run_id,
        node_count: 5
      }

      assert :ok = Events.dual_emit(event, run_id: run_id)

      # Verify it was persisted
      {:ok, events} = Events.read_run_events(run_id)
      assert length(events) >= 1

      persisted = List.last(events)
      assert persisted.type == "pipeline_started"
      assert persisted.data["graph_id"] == "TestGraph"
      assert persisted.data["run_id"] == run_id
      assert is_map(persisted.metadata)
      assert Map.has_key?(persisted.metadata, "source_node")
    end

    test "persists stage_started event" do
      run_id = "run_test_#{System.unique_integer([:positive])}"

      event = %{type: :stage_started, node_id: "build_prompt"}
      assert :ok = Events.dual_emit(event, run_id: run_id)

      {:ok, events} = Events.read_run_events(run_id)
      assert length(events) == 1
      assert hd(events).data["node_id"] == "build_prompt"
    end

    test "persists pipeline_completed event" do
      run_id = "run_test_#{System.unique_integer([:positive])}"

      event = %{
        type: :pipeline_completed,
        completed_nodes: ["start", "process", "done"],
        duration_ms: 1234
      }

      assert :ok = Events.dual_emit(event, run_id: run_id)

      {:ok, events} = Events.read_run_events(run_id)
      assert length(events) == 1
      assert hd(events).data["duration_ms"] == 1234
    end

    test "includes source_node in metadata" do
      run_id = "run_test_#{System.unique_integer([:positive])}"

      event = %{type: :stage_started, node_id: "test_node"}
      Events.dual_emit(event, run_id: run_id)

      {:ok, [persisted]} = Events.read_run_events(run_id)
      assert persisted.metadata["source_node"] == to_string(node())
    end

    test "includes agent_id in data when provided" do
      run_id = "run_test_#{System.unique_integer([:positive])}"

      event = %{type: :stage_started, node_id: "test_node", agent_id: "agent_abc123"}
      Events.dual_emit(event, run_id: run_id, agent_id: "agent_abc123")

      {:ok, [persisted]} = Events.read_run_events(run_id)
      # durable_emit stores agent_id in the event data (sanitized from event map)
      assert persisted.data["agent_id"] == "agent_abc123"
    end

    test "multiple events form a complete run timeline" do
      run_id = "run_test_#{System.unique_integer([:positive])}"

      events = [
        %{type: :pipeline_started, graph_id: "Timeline", node_count: 3},
        %{type: :stage_started, node_id: "start"},
        %{type: :stage_completed, node_id: "start", status: :success},
        %{type: :stage_started, node_id: "process"},
        %{type: :stage_completed, node_id: "process", status: :success},
        %{type: :pipeline_completed, completed_nodes: ["start", "process"], duration_ms: 500}
      ]

      for event <- events do
        Events.dual_emit(event, run_id: run_id)
      end

      {:ok, persisted} = Events.read_run_events(run_id)
      assert length(persisted) == 6

      types = Enum.map(persisted, & &1.type)

      assert types == [
               "pipeline_started",
               "stage_started",
               "stage_completed",
               "stage_started",
               "stage_completed",
               "pipeline_completed"
             ]
    end

    test "gracefully handles missing EventLog process" do
      run_id = "run_test_#{System.unique_integer([:positive])}"
      previous = Application.fetch_env(:arbor_historian, :durable_event_log_target)
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      missing = :"orchestrator_events_missing_#{System.unique_integer([:positive])}"

      configure_historian_target(:durable_event_log_target, missing)

      event = %{type: :stage_started, node_id: "test"}

      try do
        # Should not crash — graceful degradation when durable authority is down
        assert :ok = Events.dual_emit(event, run_id: run_id)
      after
        restore_env(:arbor_historian, :durable_event_log_target, previous)
      end
    end
  end

  describe "read_run_events/2" do
    test "returns empty list for unknown run_id" do
      {:ok, events} =
        Events.read_run_events("run_nonexistent_#{System.unique_integer([:positive])}")

      assert events == []
    end
  end

  defp configure_historian_target(key, name) do
    Application.put_env(:arbor_historian, key, %{name: name, backend: ETS, opts: []})
  end

  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
end
