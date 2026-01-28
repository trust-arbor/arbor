defmodule Arbor.Historian.HistoryEntryTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Events.Event
  alias Arbor.Historian.HistoryEntry

  describe "from_event/1" do
    test "creates a HistoryEntry from an Event with encoded type" do
      {:ok, event} =
        Event.new(
          type: :"activity:agent_started",
          aggregate_id: "global",
          data: %{agent_id: "a1"},
          stream_id: "global",
          stream_version: 0,
          global_position: 0,
          causation_id: "cause_1",
          correlation_id: "corr_1",
          metadata: %{signal_id: "sig_abc", source: "arbor://test", persisted_at: DateTime.utc_now()}
        )

      entry = HistoryEntry.from_event(event)

      assert entry.category == :activity
      assert entry.type == :agent_started
      assert entry.signal_id == "sig_abc"
      assert entry.stream_id == "global"
      assert entry.event_number == 0
      assert entry.global_position == 0
      assert entry.cause_id == "cause_1"
      assert entry.correlation_id == "corr_1"
      assert entry.source == "arbor://test"
      assert entry.data == %{agent_id: "a1"}
      assert String.starts_with?(entry.id, "hist_")
    end

    test "handles event without signal_id in metadata" do
      {:ok, event} =
        Event.new(
          type: :"security:authorization",
          aggregate_id: "agent:a1",
          data: %{},
          metadata: %{}
        )

      entry = HistoryEntry.from_event(event)

      assert entry.signal_id == event.id
      assert entry.category == :security
      assert entry.type == :authorization
    end

    test "handles single-segment type" do
      {:ok, event} =
        Event.new(
          type: :unknown_type,
          aggregate_id: "test",
          data: %{},
          metadata: %{}
        )

      entry = HistoryEntry.from_event(event)

      assert entry.category == :unknown
      assert entry.type == :unknown_type
    end
  end

  describe "matches?/2" do
    setup do
      {:ok, event} =
        Event.new(
          type: :"activity:agent_started",
          aggregate_id: "global",
          data: %{agent_id: "a1"},
          stream_id: "global",
          stream_version: 0,
          global_position: 0,
          correlation_id: "corr_1",
          metadata: %{signal_id: "sig_1", source: "arbor://test/agent"}
        )

      %{entry: HistoryEntry.from_event(event)}
    end

    test "matches by category", %{entry: entry} do
      assert HistoryEntry.matches?(entry, %{category: :activity})
      refute HistoryEntry.matches?(entry, %{category: :security})
    end

    test "matches by type", %{entry: entry} do
      assert HistoryEntry.matches?(entry, %{type: :agent_started})
      refute HistoryEntry.matches?(entry, %{type: :agent_stopped})
    end

    test "matches by source", %{entry: entry} do
      assert HistoryEntry.matches?(entry, %{source: "arbor://test/agent"})
      refute HistoryEntry.matches?(entry, %{source: "arbor://other"})
    end

    test "matches by correlation_id", %{entry: entry} do
      assert HistoryEntry.matches?(entry, %{correlation_id: "corr_1"})
      refute HistoryEntry.matches?(entry, %{correlation_id: "corr_2"})
    end

    test "matches by time range", %{entry: entry} do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert HistoryEntry.matches?(entry, %{from: past, to: future})
      refute HistoryEntry.matches?(entry, %{from: future, to: DateTime.add(future, 3600, :second)})
    end

    test "matches with multiple filters (AND logic)", %{entry: entry} do
      assert HistoryEntry.matches?(entry, %{category: :activity, type: :agent_started})
      refute HistoryEntry.matches?(entry, %{category: :activity, type: :agent_stopped})
    end

    test "matches with empty filters", %{entry: entry} do
      assert HistoryEntry.matches?(entry, %{})
    end

    test "accepts keyword list filters", %{entry: entry} do
      assert HistoryEntry.matches?(entry, category: :activity)
    end
  end
end
