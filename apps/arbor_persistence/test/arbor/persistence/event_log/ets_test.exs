defmodule Arbor.Persistence.EventLog.ETSTest do
  use ExUnit.Case, async: true

  alias Arbor.Persistence.EventLog.ETS
  alias Arbor.Persistence.Event

  setup do
    name = :"el_ets_#{:erlang.unique_integer([:positive])}"
    start_supervised!({ETS, name: name})
    {:ok, name: name}
  end

  describe "append/3" do
    test "appends a single event", %{name: name} do
      event = Event.new("stream-1", "test_event", %{value: 1})
      assert {:ok, [persisted]} = ETS.append("stream-1", event, name: name)

      assert persisted.stream_id == "stream-1"
      assert persisted.event_number == 1
      assert persisted.global_position == 1
    end

    test "appends multiple events with incrementing numbers", %{name: name} do
      events = [
        Event.new("stream-1", "evt1", %{v: 1}),
        Event.new("stream-1", "evt2", %{v: 2}),
        Event.new("stream-1", "evt3", %{v: 3})
      ]

      {:ok, persisted} = ETS.append("stream-1", events, name: name)
      assert length(persisted) == 3
      numbers = Enum.map(persisted, & &1.event_number)
      assert numbers == [1, 2, 3]
    end

    test "maintains separate numbering per stream", %{name: name} do
      {:ok, [e1]} = ETS.append("s1", Event.new("s1", "t", %{}), name: name)
      {:ok, [e2]} = ETS.append("s2", Event.new("s2", "t", %{}), name: name)
      {:ok, [e3]} = ETS.append("s1", Event.new("s1", "t", %{}), name: name)

      assert e1.event_number == 1
      assert e2.event_number == 1
      assert e3.event_number == 2

      # Global positions are monotonic across streams
      assert e1.global_position == 1
      assert e2.global_position == 2
      assert e3.global_position == 3
    end
  end

  describe "read_stream/2" do
    test "reads all events from a stream", %{name: name} do
      events = for i <- 1..5, do: Event.new("s1", "type_#{i}", %{i: i})
      ETS.append("s1", events, name: name)

      {:ok, read} = ETS.read_stream("s1", name: name)
      assert length(read) == 5
      assert Enum.map(read, & &1.event_number) == [1, 2, 3, 4, 5]
    end

    test "reads from a specific event number", %{name: name} do
      events = for i <- 1..5, do: Event.new("s1", "type_#{i}", %{i: i})
      ETS.append("s1", events, name: name)

      {:ok, read} = ETS.read_stream("s1", name: name, from: 3)
      assert length(read) == 3
      assert hd(read).event_number == 3
    end

    test "limits results", %{name: name} do
      events = for i <- 1..5, do: Event.new("s1", "t", %{i: i})
      ETS.append("s1", events, name: name)

      {:ok, read} = ETS.read_stream("s1", name: name, limit: 2)
      assert length(read) == 2
    end

    test "reads backward", %{name: name} do
      events = for i <- 1..3, do: Event.new("s1", "t", %{i: i})
      ETS.append("s1", events, name: name)

      {:ok, read} = ETS.read_stream("s1", name: name, direction: :backward)
      numbers = Enum.map(read, & &1.event_number)
      assert numbers == [3, 2, 1]
    end

    test "returns empty for nonexistent stream", %{name: name} do
      {:ok, read} = ETS.read_stream("nonexistent", name: name)
      assert read == []
    end
  end

  describe "read_all/1" do
    test "reads all events in global order", %{name: name} do
      ETS.append("s1", Event.new("s1", "a", %{}), name: name)
      ETS.append("s2", Event.new("s2", "b", %{}), name: name)
      ETS.append("s1", Event.new("s1", "c", %{}), name: name)

      {:ok, all} = ETS.read_all(name: name)
      assert length(all) == 3
      types = Enum.map(all, & &1.type)
      assert types == ["a", "b", "c"]
    end

    test "reads from a global position", %{name: name} do
      for i <- 1..5 do
        ETS.append("s1", Event.new("s1", "t#{i}", %{}), name: name)
      end

      {:ok, all} = ETS.read_all(name: name, from: 3)
      assert length(all) == 3
      assert hd(all).global_position == 3
    end

    test "limits results", %{name: name} do
      for i <- 1..5 do
        ETS.append("s1", Event.new("s1", "t#{i}", %{}), name: name)
      end

      {:ok, all} = ETS.read_all(name: name, limit: 2)
      assert length(all) == 2
    end
  end

  describe "stream_exists?/2" do
    test "returns true for existing stream", %{name: name} do
      ETS.append("s1", Event.new("s1", "t", %{}), name: name)
      assert ETS.stream_exists?("s1", name: name)
    end

    test "returns false for nonexistent stream", %{name: name} do
      refute ETS.stream_exists?("nope", name: name)
    end
  end

  describe "stream_version/2" do
    test "returns current version", %{name: name} do
      ETS.append("s1", Event.new("s1", "t", %{}), name: name)
      ETS.append("s1", Event.new("s1", "t", %{}), name: name)
      assert {:ok, 2} = ETS.stream_version("s1", name: name)
    end

    test "returns 0 for nonexistent stream", %{name: name} do
      assert {:ok, 0} = ETS.stream_version("nope", name: name)
    end
  end

  describe "subscribe/3" do
    test "notifies subscriber of new events", %{name: name} do
      {:ok, _ref} = ETS.subscribe("s1", self(), name: name)
      ETS.append("s1", Event.new("s1", "test_type", %{v: 1}), name: name)

      assert_receive {:event, %Event{type: "test_type", stream_id: "s1"}}
    end

    test "notifies :all subscribers", %{name: name} do
      {:ok, _ref} = ETS.subscribe(:all, self(), name: name)
      ETS.append("s1", Event.new("s1", "from_s1", %{}), name: name)
      ETS.append("s2", Event.new("s2", "from_s2", %{}), name: name)

      assert_receive {:event, %Event{type: "from_s1"}}
      assert_receive {:event, %Event{type: "from_s2"}}
    end

    test "cleans up subscriber on process death", %{name: name} do
      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, _ref} = ETS.subscribe("s1", pid, name: name)
      send(pid, :stop)
      Process.sleep(50)

      # Should not crash when appending after subscriber died
      assert {:ok, _} = ETS.append("s1", Event.new("s1", "t", %{}), name: name)
    end
  end
end
