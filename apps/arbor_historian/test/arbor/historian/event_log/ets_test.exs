defmodule Arbor.Historian.EventLog.ETSTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Events.Event
  alias Arbor.Historian.EventLog.ETS, as: EventLogETS

  setup do
    {:ok, pid} = EventLogETS.start_link(name: :"ets_test_#{System.unique_integer([:positive])}")
    %{log: pid}
  end

  defp make_event(type, data \\ %{}) do
    {:ok, event} =
      Event.new(type: type, aggregate_id: "test", data: data)

    event
  end

  describe "append/3" do
    test "appends an event and returns position", %{log: log} do
      event = make_event(:test_event, %{value: 1})
      assert {:ok, 0} = EventLogETS.append(log, "stream_a", event)
      assert {:ok, 1} = EventLogETS.append(log, "stream_a", make_event(:test_event_2))
    end

    test "positions are per-stream", %{log: log} do
      assert {:ok, 0} = EventLogETS.append(log, "stream_a", make_event(:ev1))
      assert {:ok, 0} = EventLogETS.append(log, "stream_b", make_event(:ev2))
      assert {:ok, 1} = EventLogETS.append(log, "stream_a", make_event(:ev3))
    end

    test "sets stream_id and positions on events", %{log: log} do
      EventLogETS.append(log, "my_stream", make_event(:ev1))
      {:ok, [event]} = EventLogETS.read_stream(log, "my_stream")

      assert event.stream_id == "my_stream"
      assert event.stream_version == 0
      assert event.global_position == 0
    end
  end

  describe "read_stream/2" do
    test "returns empty list for unknown stream", %{log: log} do
      assert {:ok, []} = EventLogETS.read_stream(log, "nonexistent")
    end

    test "returns events in order", %{log: log} do
      EventLogETS.append(log, "s1", make_event(:first))
      EventLogETS.append(log, "s1", make_event(:second))
      EventLogETS.append(log, "s1", make_event(:third))

      {:ok, events} = EventLogETS.read_stream(log, "s1")
      assert length(events) == 3
      assert Enum.map(events, & &1.type) == [:first, :second, :third]
    end

    test "streams are isolated", %{log: log} do
      EventLogETS.append(log, "s1", make_event(:ev_a))
      EventLogETS.append(log, "s2", make_event(:ev_b))

      {:ok, s1} = EventLogETS.read_stream(log, "s1")
      {:ok, s2} = EventLogETS.read_stream(log, "s2")

      assert length(s1) == 1
      assert length(s2) == 1
      assert hd(s1).type == :ev_a
      assert hd(s2).type == :ev_b
    end
  end

  describe "read_all/1" do
    test "returns all events across streams in global order", %{log: log} do
      EventLogETS.append(log, "s1", make_event(:first))
      EventLogETS.append(log, "s2", make_event(:second))
      EventLogETS.append(log, "s1", make_event(:third))

      {:ok, events} = EventLogETS.read_all(log)
      assert length(events) == 3
      assert Enum.map(events, & &1.type) == [:first, :second, :third]
    end

    test "returns empty for fresh log", %{log: log} do
      assert {:ok, []} = EventLogETS.read_all(log)
    end
  end

  describe "list_streams/1" do
    test "returns all known stream ids", %{log: log} do
      EventLogETS.append(log, "alpha", make_event(:ev1))
      EventLogETS.append(log, "beta", make_event(:ev2))
      EventLogETS.append(log, "gamma", make_event(:ev3))

      {:ok, streams} = EventLogETS.list_streams(log)
      assert Enum.sort(streams) == ["alpha", "beta", "gamma"]
    end

    test "returns empty for fresh log", %{log: log} do
      assert {:ok, []} = EventLogETS.list_streams(log)
    end
  end

  describe "stream_size/2" do
    test "returns count for a stream", %{log: log} do
      EventLogETS.append(log, "s1", make_event(:ev1))
      EventLogETS.append(log, "s1", make_event(:ev2))

      assert {:ok, 2} = EventLogETS.stream_size(log, "s1")
    end

    test "returns 0 for unknown stream", %{log: log} do
      assert {:ok, 0} = EventLogETS.stream_size(log, "unknown")
    end
  end

  describe "total_size/1" do
    test "returns total events across all streams", %{log: log} do
      EventLogETS.append(log, "s1", make_event(:ev1))
      EventLogETS.append(log, "s2", make_event(:ev2))
      EventLogETS.append(log, "s1", make_event(:ev3))

      assert {:ok, 3} = EventLogETS.total_size(log)
    end

    test "returns 0 for empty log", %{log: log} do
      assert {:ok, 0} = EventLogETS.total_size(log)
    end
  end
end
