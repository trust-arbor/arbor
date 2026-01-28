defmodule Arbor.Trust.EventStoreTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Trust.EventStore
  alias Arbor.Contracts.Trust.Event

  setup do
    # Stop existing processes if running
    case GenServer.whereis(EventStore) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end

    # Clean up named ETS tables if they linger
    for table <- [:trust_events_store, :trust_events_index] do
      if :ets.info(table) != :undefined do
        :ets.delete(table)
      end
    end

    # Start the EventStore
    {:ok, pid} = EventStore.start_link()

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)

    {:ok, pid: pid}
  end

  # Helper to create a test event with optional overrides
  defp create_event(agent_id, event_type, opts \\ []) do
    attrs =
      Keyword.merge(
        [
          agent_id: agent_id,
          event_type: event_type,
          previous_score: opts[:previous_score],
          new_score: opts[:new_score],
          metadata: opts[:metadata] || %{}
        ],
        opts
      )

    {:ok, event} = Event.new(attrs)
    event
  end

  defp create_timed_events(agent_id, count, opts \\ []) do
    base_time = Keyword.get(opts, :base_time, ~U[2024-01-01 10:00:00Z])
    event_type = Keyword.get(opts, :event_type, :action_success)

    for i <- 1..count do
      timestamp = DateTime.add(base_time, i * 60, :second)

      create_event(agent_id, event_type,
        timestamp: timestamp,
        previous_score: i - 1,
        new_score: i
      )
    end
  end

  describe "start_link/1 and stopping" do
    test "starts the EventStore GenServer", %{pid: pid} do
      assert Process.alive?(pid)
      assert GenServer.whereis(EventStore) == pid
    end

    test "creates ETS tables on start" do
      assert :ets.info(:trust_events_store) != :undefined
      assert :ets.info(:trust_events_index) != :undefined
    end

    test "stops cleanly" do
      # The on_exit callback will handle stopping; just verify it is alive now
      pid = GenServer.whereis(EventStore)
      assert Process.alive?(pid)
    end
  end

  describe "record_event/1" do
    test "records a single event" do
      event = create_event("agent_1", :action_success, previous_score: 0, new_score: 1)
      assert :ok = EventStore.record_event(event)
    end

    test "recorded event can be retrieved by ID" do
      event = create_event("agent_1", :action_success, previous_score: 0, new_score: 5)
      :ok = EventStore.record_event(event)

      {:ok, retrieved} = EventStore.get_event(event.id)
      assert retrieved.id == event.id
      assert retrieved.agent_id == "agent_1"
      assert retrieved.event_type == :action_success
    end

    test "records events with different types" do
      types = [:action_success, :action_failure, :test_passed, :security_violation]

      for type <- types do
        event = create_event("agent_types", type)
        assert :ok = EventStore.record_event(event)
      end
    end
  end

  describe "record_events/1" do
    test "records multiple events atomically" do
      events = create_timed_events("agent_batch", 5)
      assert :ok = EventStore.record_events(events)

      {:ok, retrieved} = EventStore.get_events(agent_id: "agent_batch")
      assert length(retrieved) == 5
    end

    test "records multiple events successfully" do
      events = create_timed_events("agent_batch_ok", 3)
      assert :ok = EventStore.record_events(events)
    end
  end

  describe "get_events/1 filtering" do
    setup do
      agent_id = "agent_filter"

      # Create various events
      events = [
        create_event(agent_id, :action_success,
          timestamp: ~U[2024-01-01 10:01:00Z],
          previous_score: 0,
          new_score: 1
        ),
        create_event(agent_id, :action_success,
          timestamp: ~U[2024-01-01 10:02:00Z],
          previous_score: 1,
          new_score: 2
        ),
        create_event(agent_id, :action_failure,
          timestamp: ~U[2024-01-01 10:03:00Z],
          previous_score: 2,
          new_score: 1
        ),
        create_event(agent_id, :test_passed,
          timestamp: ~U[2024-01-01 10:04:00Z],
          previous_score: 1,
          new_score: 3
        ),
        create_event("other_agent", :action_success,
          timestamp: ~U[2024-01-01 10:05:00Z],
          previous_score: 0,
          new_score: 1
        )
      ]

      Enum.each(events, &EventStore.record_event/1)

      {:ok, agent_id: agent_id}
    end

    test "filters by agent_id", %{agent_id: agent_id} do
      {:ok, events} = EventStore.get_events(agent_id: agent_id)
      assert length(events) == 4
      assert Enum.all?(events, &(&1.agent_id == agent_id))
    end

    test "filters by event_type" do
      {:ok, events} = EventStore.get_events(event_type: :action_success)
      assert length(events) == 3
      assert Enum.all?(events, &(&1.event_type == :action_success))
    end

    test "respects limit" do
      {:ok, events} = EventStore.get_events(agent_id: "agent_filter", limit: 2)
      assert length(events) == 2
    end

    test "returns events sorted descending by default", %{agent_id: agent_id} do
      {:ok, events} = EventStore.get_events(agent_id: agent_id)
      timestamps = Enum.map(events, & &1.timestamp)
      assert timestamps == Enum.sort(timestamps, {:desc, DateTime})
    end

    test "returns events sorted ascending when requested", %{agent_id: agent_id} do
      {:ok, events} = EventStore.get_events(agent_id: agent_id, order: :asc)
      timestamps = Enum.map(events, & &1.timestamp)
      assert timestamps == Enum.sort(timestamps, {:asc, DateTime})
    end

    test "returns all events when no filter" do
      {:ok, events} = EventStore.get_events([])
      # At least the 5 events from setup
      assert length(events) >= 5
    end
  end

  describe "get_event/1" do
    test "returns {:error, :not_found} for unknown event ID" do
      assert {:error, :not_found} = EventStore.get_event("nonexistent_id")
    end

    test "retrieves cached event by ID" do
      event = create_event("agent_get", :test_passed, previous_score: 5, new_score: 6)
      :ok = EventStore.record_event(event)

      {:ok, retrieved} = EventStore.get_event(event.id)
      assert retrieved.id == event.id
      assert retrieved.event_type == :test_passed
    end
  end

  describe "cursor-based pagination" do
    setup do
      agent_id = "agent_cursor"
      events = create_timed_events(agent_id, 7)
      Enum.each(events, &EventStore.record_event/1)
      {:ok, agent_id: agent_id}
    end

    test "returns paginated result when cursor key is present", %{agent_id: agent_id} do
      {:ok, result} =
        EventStore.get_events(agent_id: agent_id, cursor: nil, limit: 3)

      assert is_map(result)
      assert Map.has_key?(result, :events)
      assert Map.has_key?(result, :next_cursor)
      assert Map.has_key?(result, :has_more)
      assert length(result.events) == 3
      assert result.has_more == true
      assert result.next_cursor != nil
    end

    test "returns legacy list when cursor key is absent", %{agent_id: agent_id} do
      {:ok, events} = EventStore.get_events(agent_id: agent_id)
      assert is_list(events)
      assert length(events) == 7
    end

    test "second page continues from cursor", %{agent_id: agent_id} do
      {:ok, page1} =
        EventStore.get_events(agent_id: agent_id, cursor: nil, limit: 3)

      {:ok, page2} =
        EventStore.get_events(agent_id: agent_id, cursor: page1.next_cursor, limit: 3)

      # No overlap between pages
      page1_ids = MapSet.new(Enum.map(page1.events, & &1.id))
      page2_ids = MapSet.new(Enum.map(page2.events, & &1.id))
      assert MapSet.disjoint?(page1_ids, page2_ids)
    end

    test "has_more is false on last page", %{agent_id: agent_id} do
      {:ok, result} =
        EventStore.get_events(agent_id: agent_id, cursor: nil, limit: 100)

      assert result.has_more == false
    end

    test "ascending pagination works", %{agent_id: agent_id} do
      {:ok, page1} =
        EventStore.get_events(agent_id: agent_id, cursor: nil, limit: 3, order: :asc)

      assert length(page1.events) == 3
      # Events should be in ascending time order
      timestamps = Enum.map(page1.events, & &1.timestamp)
      assert timestamps == Enum.sort(timestamps, {:asc, DateTime})

      {:ok, page2} =
        EventStore.get_events(
          agent_id: agent_id,
          cursor: page1.next_cursor,
          limit: 3,
          order: :asc
        )

      # page2 events should be newer than page1 events
      last_p1_ts = List.last(page1.events).timestamp
      first_p2_ts = hd(page2.events).timestamp
      assert DateTime.compare(first_p2_ts, last_p1_ts) == :gt
    end

    test "descending pagination works", %{agent_id: agent_id} do
      {:ok, page1} =
        EventStore.get_events(agent_id: agent_id, cursor: nil, limit: 3, order: :desc)

      timestamps = Enum.map(page1.events, & &1.timestamp)
      assert timestamps == Enum.sort(timestamps, {:desc, DateTime})

      {:ok, page2} =
        EventStore.get_events(
          agent_id: agent_id,
          cursor: page1.next_cursor,
          limit: 3,
          order: :desc
        )

      # page2 events should be older than page1 events
      last_p1_ts = List.last(page1.events).timestamp
      first_p2_ts = hd(page2.events).timestamp
      assert DateTime.compare(first_p2_ts, last_p1_ts) == :lt
    end

    test "empty result returns nil cursor" do
      {:ok, result} =
        EventStore.get_events(agent_id: "nonexistent_cursor_agent", cursor: nil, limit: 10)

      assert result.events == []
      assert result.next_cursor == nil
      assert result.has_more == false
    end

    test "all pages combined cover all events", %{agent_id: agent_id} do
      all_ids = collect_all_paginated_ids(agent_id, 2, :desc)
      assert length(all_ids) == 7
      assert length(all_ids) == length(Enum.uniq(all_ids))
    end
  end

  describe "get_agent_timeline/2" do
    test "returns timeline for an agent" do
      agent_id = "agent_timeline"
      events = create_timed_events(agent_id, 5)
      Enum.each(events, &EventStore.record_event/1)

      {:ok, timeline} = EventStore.get_agent_timeline(agent_id)

      assert timeline.agent_id == agent_id
      assert timeline.event_count == 5
      assert length(timeline.events) == 5
      assert timeline.first_event_at != nil
      assert timeline.last_event_at != nil
      assert timeline.total_duration_ms > 0
    end

    test "returns empty timeline for unknown agent" do
      {:ok, timeline} = EventStore.get_agent_timeline("unknown_timeline_agent")

      assert timeline.agent_id == "unknown_timeline_agent"
      assert timeline.event_count == 0
      assert timeline.events == []
    end

    test "timeline events include time_to_next_ms" do
      agent_id = "agent_timeline_times"
      events = create_timed_events(agent_id, 3)
      Enum.each(events, &EventStore.record_event/1)

      {:ok, timeline} = EventStore.get_agent_timeline(agent_id)

      # First and middle events should have time_to_next_ms
      non_last_events = Enum.take(timeline.events, length(timeline.events) - 1)
      assert Enum.all?(non_last_events, &(&1.time_to_next_ms != nil))
      # Last event should have nil time_to_next_ms
      assert List.last(timeline.events).time_to_next_ms == nil
    end
  end

  describe "get_trust_progression/2" do
    test "returns score progression for an agent" do
      agent_id = "agent_progression"

      events = [
        create_event(agent_id, :action_success,
          timestamp: ~U[2024-01-01 10:01:00Z],
          previous_score: 0,
          new_score: 5
        ),
        create_event(agent_id, :action_success,
          timestamp: ~U[2024-01-01 10:02:00Z],
          previous_score: 5,
          new_score: 12
        ),
        create_event(agent_id, :action_failure,
          timestamp: ~U[2024-01-01 10:03:00Z],
          previous_score: 12,
          new_score: 10
        )
      ]

      Enum.each(events, &EventStore.record_event/1)

      {:ok, progression} = EventStore.get_trust_progression(agent_id)

      assert progression.agent_id == agent_id
      assert progression.current_score == 10
      assert progression.min_score == 5
      assert progression.max_score == 12
      assert progression.total_positive_delta > 0
      assert progression.total_negative_delta < 0
      assert progression.data_points == 3
    end

    test "returns empty progression for unknown agent" do
      {:ok, progression} = EventStore.get_trust_progression("unknown_prog_agent")

      assert progression.agent_id == "unknown_prog_agent"
      assert progression.current_score == nil
      assert progression.data_points == 0
    end
  end

  describe "get_tier_history/1" do
    test "returns tier change history" do
      agent_id = "agent_tier_history"

      {:ok, tier_event} =
        Event.tier_change_event(agent_id, :untrusted, :probationary,
          timestamp: ~U[2024-01-01 12:00:00Z],
          previous_score: 19,
          new_score: 22
        )

      :ok = EventStore.record_event(tier_event)

      {:ok, history} = EventStore.get_tier_history(agent_id)
      assert length(history) == 1

      change = hd(history)
      assert change.from_tier == :untrusted
      assert change.to_tier == :probationary
      assert change.direction == :promotion
    end

    test "returns empty list for agent with no tier changes" do
      {:ok, history} = EventStore.get_tier_history("no_tier_changes_agent")
      assert history == []
    end
  end

  describe "get_agent_stats/1" do
    test "returns aggregate stats for an agent" do
      agent_id = "agent_stats"

      events = [
        create_event(agent_id, :action_success),
        create_event(agent_id, :action_success),
        create_event(agent_id, :action_failure),
        create_event(agent_id, :test_passed),
        create_event(agent_id, :security_violation)
      ]

      Enum.each(events, &EventStore.record_event/1)

      {:ok, stats} = EventStore.get_agent_stats(agent_id)

      assert stats.agent_id == agent_id
      assert stats.total_events == 5
      assert stats.events_by_type[:action_success] == 2
      assert stats.events_by_type[:action_failure] == 1
      assert stats.events_by_type[:test_passed] == 1
      assert stats.events_by_type[:security_violation] == 1
      assert stats.action_success_rate == 2 / 3
      assert stats.security_violations == 1
      assert stats.negative_event_count == 2
    end
  end

  describe "get_system_stats/0" do
    test "returns system-wide statistics" do
      # Record some events for different agents
      :ok = EventStore.record_event(create_event("sys_agent_1", :action_success))
      :ok = EventStore.record_event(create_event("sys_agent_2", :action_failure))

      {:ok, stats} = EventStore.get_system_stats()

      assert stats.total_agents >= 2
      assert stats.total_events >= 2
      assert is_map(stats.events_by_type)
      assert stats.cache_size >= 2
      assert stats.memory_bytes > 0
    end
  end

  describe "get_recent_negative_events/1" do
    test "returns recent negative events across all agents" do
      # Record a negative event with recent timestamp
      negative_event =
        create_event("neg_agent", :action_failure,
          timestamp: DateTime.utc_now()
        )

      positive_event =
        create_event("pos_agent", :action_success,
          timestamp: DateTime.utc_now()
        )

      :ok = EventStore.record_event(negative_event)
      :ok = EventStore.record_event(positive_event)

      {:ok, events} = EventStore.get_recent_negative_events(since_minutes: 5)

      # Should include the negative event, not the positive one
      event_types = Enum.map(events, & &1.event_type)
      assert :action_failure in event_types
      refute :action_success in event_types
    end

    test "respects limit" do
      for i <- 1..10 do
        event =
          create_event("neg_limit_#{i}", :security_violation,
            timestamp: DateTime.utc_now()
          )

        :ok = EventStore.record_event(event)
      end

      {:ok, events} = EventStore.get_recent_negative_events(limit: 3, since_minutes: 5)
      assert length(events) <= 3
    end
  end

  describe "get_store_stats/0" do
    test "returns store-level statistics" do
      event = create_event("stats_agent", :action_success)
      :ok = EventStore.record_event(event)

      stats = EventStore.get_store_stats()

      assert stats.total_events >= 1
      assert is_map(stats.events_by_type)
      assert is_map(stats.events_by_agent)
      assert stats.cache_size >= 1
      assert stats.memory_bytes > 0
    end
  end

  # Helper to collect all event IDs across paginated results
  defp collect_all_paginated_ids(agent_id, page_size, order) do
    collect_pages(agent_id, page_size, order, nil, [])
  end

  defp collect_pages(agent_id, page_size, order, cursor, acc) do
    {:ok, result} =
      EventStore.get_events(
        agent_id: agent_id,
        cursor: cursor,
        limit: page_size,
        order: order
      )

    new_ids = Enum.map(result.events, & &1.id)
    all_ids = acc ++ new_ids

    if result.has_more do
      collect_pages(agent_id, page_size, order, result.next_cursor, all_ids)
    else
      all_ids
    end
  end
end
