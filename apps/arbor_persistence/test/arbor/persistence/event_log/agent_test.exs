defmodule Arbor.Persistence.EventLog.AgentTest do
  use ExUnit.Case, async: true

  alias Arbor.Persistence.EventLog.Agent, as: ELAgent
  alias Arbor.Persistence.Event

  setup do
    name = :"el_agent_#{:erlang.unique_integer([:positive])}"
    start_supervised!({ELAgent, name: name})
    {:ok, name: name}
  end

  describe "append/3" do
    test "appends a single event", %{name: name} do
      event = Event.new("stream-1", "test_event", %{value: 1})
      assert {:ok, [persisted]} = ELAgent.append("stream-1", event, name: name)

      assert persisted.stream_id == "stream-1"
      assert persisted.event_number == 1
      assert persisted.global_position == 1
    end

    test "appends multiple events", %{name: name} do
      events = [
        Event.new("s1", "a", %{}),
        Event.new("s1", "b", %{})
      ]

      {:ok, persisted} = ELAgent.append("s1", events, name: name)
      assert length(persisted) == 2
      assert Enum.map(persisted, & &1.event_number) == [1, 2]
    end

    test "maintains separate numbering per stream", %{name: name} do
      {:ok, [e1]} = ELAgent.append("s1", Event.new("s1", "t", %{}), name: name)
      {:ok, [e2]} = ELAgent.append("s2", Event.new("s2", "t", %{}), name: name)

      assert e1.event_number == 1
      assert e2.event_number == 1
      assert e1.global_position == 1
      assert e2.global_position == 2
    end
  end

  describe "read_stream/2" do
    test "reads all events from a stream", %{name: name} do
      events = for i <- 1..3, do: Event.new("s1", "t#{i}", %{})
      ELAgent.append("s1", events, name: name)

      {:ok, read} = ELAgent.read_stream("s1", name: name)
      assert length(read) == 3
    end

    test "reads from a specific event number", %{name: name} do
      events = for i <- 1..5, do: Event.new("s1", "t#{i}", %{})
      ELAgent.append("s1", events, name: name)

      {:ok, read} = ELAgent.read_stream("s1", name: name, from: 3)
      assert length(read) == 3
    end

    test "limits results", %{name: name} do
      events = for i <- 1..5, do: Event.new("s1", "t", %{i: i})
      ELAgent.append("s1", events, name: name)

      {:ok, read} = ELAgent.read_stream("s1", name: name, limit: 2)
      assert length(read) == 2
    end

    test "reads backward", %{name: name} do
      events = for i <- 1..3, do: Event.new("s1", "t", %{i: i})
      ELAgent.append("s1", events, name: name)

      {:ok, read} = ELAgent.read_stream("s1", name: name, direction: :backward)
      numbers = Enum.map(read, & &1.event_number)
      assert numbers == [3, 2, 1]
    end
  end

  describe "read_all/1" do
    test "reads all events in global order", %{name: name} do
      ELAgent.append("s1", Event.new("s1", "a", %{}), name: name)
      ELAgent.append("s2", Event.new("s2", "b", %{}), name: name)

      {:ok, all} = ELAgent.read_all(name: name)
      assert length(all) == 2
      assert Enum.map(all, & &1.type) == ["a", "b"]
    end

    test "reads from global position", %{name: name} do
      for i <- 1..5 do
        ELAgent.append("s1", Event.new("s1", "t#{i}", %{}), name: name)
      end

      {:ok, all} = ELAgent.read_all(name: name, from: 3)
      assert length(all) == 3
    end
  end

  describe "stream_exists?/2 and stream_version/2" do
    test "stream_exists? returns true for existing stream", %{name: name} do
      ELAgent.append("s1", Event.new("s1", "t", %{}), name: name)
      assert ELAgent.stream_exists?("s1", name: name)
    end

    test "stream_exists? returns false for missing stream", %{name: name} do
      refute ELAgent.stream_exists?("nope", name: name)
    end

    test "stream_version returns current version", %{name: name} do
      ELAgent.append("s1", Event.new("s1", "t", %{}), name: name)
      ELAgent.append("s1", Event.new("s1", "t", %{}), name: name)
      assert {:ok, 2} = ELAgent.stream_version("s1", name: name)
    end

    test "stream_version returns 0 for missing stream", %{name: name} do
      assert {:ok, 0} = ELAgent.stream_version("nope", name: name)
    end
  end
end
