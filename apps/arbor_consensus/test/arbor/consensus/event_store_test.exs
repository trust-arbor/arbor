defmodule Arbor.Consensus.EventStoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Consensus.EventStore
  alias Arbor.Contracts.Consensus.ConsensusEvent
  alias EventLogETS, as: EventLogETS

  setup do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    table_name = :"test_events_#{:rand.uniform(1_000_000)}"
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    name = :"test_es_#{:rand.uniform(1_000_000)}"
    {:ok, pid} = EventStore.start_link(name: name, table_name: table_name)
    %{store: name, pid: pid}
  end

  defp build_event(overrides \\ %{}) do
    {:ok, event} =
      ConsensusEvent.new(
        Map.merge(
          %{
            event_type: :proposal_submitted,
            proposal_id: "prop_test_#{:rand.uniform(10000)}",
            agent_id: "agent_1"
          },
          overrides
        )
      )

    event
  end

  describe "append/2" do
    test "stores an event", %{store: store} do
      event = build_event()
      assert :ok = EventStore.append(event, store)
      assert EventStore.count(store) == 1
    end

    test "stores multiple events", %{store: store} do
      for _ <- 1..5 do
        EventStore.append(build_event(), store)
      end

      assert EventStore.count(store) == 5
    end
  end

  describe "query/2" do
    test "returns all events when no filters", %{store: store} do
      EventStore.append(build_event(), store)
      EventStore.append(build_event(), store)

      events = EventStore.query([], store)
      assert length(events) == 2
    end

    test "filters by proposal_id", %{store: store} do
      EventStore.append(build_event(%{proposal_id: "prop_a"}), store)
      EventStore.append(build_event(%{proposal_id: "prop_b"}), store)
      EventStore.append(build_event(%{proposal_id: "prop_a"}), store)

      events = EventStore.query([proposal_id: "prop_a"], store)
      assert length(events) == 2
      assert Enum.all?(events, &(&1.proposal_id == "prop_a"))
    end

    test "filters by event_type", %{store: store} do
      EventStore.append(build_event(%{event_type: :proposal_submitted}), store)
      EventStore.append(build_event(%{event_type: :decision_reached}), store)
      EventStore.append(build_event(%{event_type: :proposal_submitted}), store)

      events = EventStore.query([event_type: :proposal_submitted], store)
      assert length(events) == 2
    end

    test "filters by agent_id", %{store: store} do
      EventStore.append(build_event(%{agent_id: "agent_1"}), store)
      EventStore.append(build_event(%{agent_id: "agent_2"}), store)

      events = EventStore.query([agent_id: "agent_1"], store)
      assert length(events) == 1
    end

    test "filters by time range (since)", %{store: store} do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      EventStore.append(build_event(), store)

      events_since_past = EventStore.query([since: past], store)
      assert length(events_since_past) == 1

      events_since_future = EventStore.query([since: future], store)
      assert events_since_future == []
    end

    test "respects limit", %{store: store} do
      for _ <- 1..10 do
        EventStore.append(build_event(), store)
      end

      events = EventStore.query([limit: 3], store)
      assert length(events) == 3
    end

    test "combines multiple filters", %{store: store} do
      EventStore.append(
        build_event(%{proposal_id: "prop_x", event_type: :proposal_submitted}),
        store
      )

      EventStore.append(
        build_event(%{proposal_id: "prop_x", event_type: :decision_reached}),
        store
      )

      EventStore.append(
        build_event(%{proposal_id: "prop_y", event_type: :proposal_submitted}),
        store
      )

      events =
        EventStore.query(
          [proposal_id: "prop_x", event_type: :proposal_submitted],
          store
        )

      assert length(events) == 1
    end
  end

  describe "get_by_proposal/2" do
    test "returns events for a specific proposal", %{store: store} do
      EventStore.append(build_event(%{proposal_id: "prop_target"}), store)
      EventStore.append(build_event(%{proposal_id: "prop_other"}), store)
      EventStore.append(build_event(%{proposal_id: "prop_target"}), store)

      events = EventStore.get_by_proposal("prop_target", store)
      assert length(events) == 2
    end

    test "returns empty list for unknown proposal", %{store: store} do
      events = EventStore.get_by_proposal("nonexistent", store)
      assert events == []
    end
  end

  describe "get_timeline/2" do
    test "returns indexed events in chronological order", %{store: store} do
      EventStore.append(
        build_event(%{proposal_id: "prop_tl", event_type: :proposal_submitted}),
        store
      )

      Process.sleep(10)

      EventStore.append(
        build_event(%{proposal_id: "prop_tl", event_type: :evaluation_submitted}),
        store
      )

      Process.sleep(10)

      EventStore.append(
        build_event(%{proposal_id: "prop_tl", event_type: :decision_reached}),
        store
      )

      timeline = EventStore.get_timeline("prop_tl", store)
      assert length(timeline) == 3

      [{0, first}, {1, second}, {2, third}] = timeline
      assert first.event_type == :proposal_submitted
      assert second.event_type == :evaluation_submitted
      assert third.event_type == :decision_reached
    end
  end

  describe "count/1" do
    test "returns 0 for empty store", %{store: store} do
      assert EventStore.count(store) == 0
    end

    test "returns correct count", %{store: store} do
      EventStore.append(build_event(), store)
      EventStore.append(build_event(), store)
      EventStore.append(build_event(), store)

      assert EventStore.count(store) == 3
    end
  end

  describe "clear/1" do
    test "removes all events", %{store: store} do
      EventStore.append(build_event(), store)
      EventStore.append(build_event(), store)

      assert EventStore.count(store) == 2

      EventStore.clear(store)
      assert EventStore.count(store) == 0
    end
  end

  describe "pruning" do
    test "prunes oldest events when over capacity" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      table_name = :"prune_test_#{:rand.uniform(1_000_000)}"
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"prune_es_#{:rand.uniform(1_000_000)}"
      {:ok, _} = EventStore.start_link(name: name, table_name: table_name, max_events: 20)

      # Add 25 events (capacity is 20)
      for i <- 1..25 do
        EventStore.append(
          build_event(%{proposal_id: "prop_#{i}"}),
          name
        )
      end

      # Should have pruned some
      count = EventStore.count(name)
      assert count <= 25
      # After pruning 10% (2 events), next inserts should also trigger prune
      # The exact count depends on timing, but should be less than 25
      assert count < 25
    end
  end

  describe "event_sink forwarding" do
    test "forwards events to event sink" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      table_name = :"sink_test_#{:rand.uniform(1_000_000)}"
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"sink_es_#{:rand.uniform(1_000_000)}"

      # Register ourselves to receive sink events
      Process.register(self(), :test_event_sink_receiver)

      {:ok, _} =
        EventStore.start_link(
          name: name,
          table_name: table_name,
          event_sink: Arbor.Consensus.TestHelpers.TestEventSink
        )

      event = build_event()
      EventStore.append(event, name)

      assert_receive {:event_sink, received_event}, 1000
      assert received_event.id == event.id

      Process.unregister(:test_event_sink_receiver)
    end
  end

  describe "query with until filter" do
    test "filters events before a given time", %{store: store} do
      EventStore.append(build_event(), store)

      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      # All events are before the future time
      events = EventStore.query([until: future], store)
      assert length(events) == 1

      # No events before the past time
      events = EventStore.query([until: past], store)
      assert events == []
    end
  end

  describe "event_log persistence" do
    test "persists events to configured event_log" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      table_name = :"elog_test_#{:rand.uniform(1_000_000)}"
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"elog_es_#{:rand.uniform(1_000_000)}"
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      elog_name = :"elog_persist_#{:rand.uniform(1_000_000)}"

      # Start an ETS event log for persistence
      {:ok, _} = EventLogETS.start_link(name: elog_name)

      {:ok, _} =
        EventStore.start_link(
          name: name,
          table_name: table_name,
          event_log: elog_name
        )

      event = build_event(%{proposal_id: "persist_prop"})
      EventStore.append(event, name)

      # Verify event was persisted to the EventLog
      {:ok, events} =
        EventLogETS.read_stream(
          "consensus:persist_prop",
          name: elog_name
        )

      assert events != []
    end
  end

  describe "query with unknown filters" do
    test "ignores unknown filter keys", %{store: store} do
      EventStore.append(build_event(), store)

      # Unknown filter should be ignored
      events = EventStore.query([unknown_key: "value"], store)
      assert length(events) == 1
    end
  end
end
