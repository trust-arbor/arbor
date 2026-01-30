defmodule Arbor.HistorianTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Integration tests for the Arbor.Historian facade.

  These test the full flow through the facade API, using an isolated
  test historian stack (no Bus subscription).
  """

  alias Arbor.Historian.QueryEngine
  alias Arbor.Historian.StreamRegistry
  alias Arbor.Historian.TestHelpers
  alias Arbor.Historian.Timeline
  alias QueryEngine.Aggregator
  alias Timeline.Span

  # These tests use the globally-started Historian application processes,
  # so we use the manual collect API for determinism.

  setup do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    ctx = TestHelpers.start_test_historian(:"facade_#{System.unique_integer([:positive])}")

    now = DateTime.utc_now()
    t1 = DateTime.add(now, -600, :second)
    t2 = DateTime.add(now, -300, :second)

    signals = [
      TestHelpers.build_agent_signal("agent_01",
        category: :activity,
        type: :agent_started,
        time: t1,
        id: "sig_facade_1",
        correlation_id: "corr_x"
      ),
      TestHelpers.build_signal(
        category: :security,
        type: :authorization,
        time: t2,
        id: "sig_facade_2",
        data: %{session_id: "sess_99"}
      ),
      TestHelpers.build_signal(
        category: :logs,
        type: :error,
        time: now,
        id: "sig_facade_3"
      )
    ]

    for s <- signals, do: TestHelpers.collect_signal(ctx, s)

    %{ctx: ctx, now: now, t1: t1, t2: t2}
  end

  describe "query API" do
    test "recent/1 returns all entries", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.read_global(event_log: ctx.event_log)
      assert length(entries) == 3
    end

    test "for_agent/2 returns agent entries", %{ctx: ctx} do
      {:ok, entries} =
        QueryEngine.read_agent("agent_01", event_log: ctx.event_log)

      assert length(entries) == 1
      assert hd(entries).type == :agent_started
    end

    test "for_category/2 returns category entries", %{ctx: ctx} do
      {:ok, entries} =
        QueryEngine.read_category(:security, event_log: ctx.event_log)

      assert length(entries) == 1
    end

    test "for_session/2 returns session entries", %{ctx: ctx} do
      {:ok, entries} =
        QueryEngine.read_session("sess_99", event_log: ctx.event_log)

      assert length(entries) == 1
    end

    test "for_correlation/2 returns correlation entries", %{ctx: ctx} do
      {:ok, entries} =
        QueryEngine.read_correlation("corr_x", event_log: ctx.event_log)

      assert length(entries) == 1
    end

    test "query/1 with filters", %{ctx: ctx} do
      {:ok, entries} =
        QueryEngine.query(event_log: ctx.event_log, category: :logs)

      assert length(entries) == 1
      assert hd(entries).category == :logs
    end

    test "find_by_signal_id/2", %{ctx: ctx} do
      {:ok, entry} =
        QueryEngine.find_by_signal_id("sig_facade_2", event_log: ctx.event_log)

      assert entry.category == :security
    end
  end

  describe "aggregation API" do
    test "count_by_category/2", %{ctx: ctx} do
      count =
        Aggregator.count_by_category(:activity,
          event_log: ctx.event_log
        )

      assert count == 1
    end

    test "error_count/1", %{ctx: ctx} do
      count = Aggregator.error_count(event_log: ctx.event_log)
      assert count == 1
    end

    test "category_distribution/1", %{ctx: ctx} do
      dist =
        Aggregator.category_distribution(event_log: ctx.event_log)

      assert dist[:activity] == 1
      assert dist[:security] == 1
      assert dist[:logs] == 1
    end
  end

  describe "timeline API" do
    test "reconstruct/2 with span", %{ctx: ctx, t1: t1, now: now} do
      from = DateTime.add(t1, -60, :second)
      span = Span.new(from: from, to: now)

      {:ok, entries} = Timeline.reconstruct(span, event_log: ctx.event_log)

      assert length(entries) == 3
    end

    test "timeline_summary/2", %{ctx: ctx, t1: t1, now: now} do
      from = DateTime.add(t1, -60, :second)
      span = Span.new(from: from, to: now)

      summary = Timeline.summary(span, event_log: ctx.event_log)

      assert summary.total == 3
      assert is_map(summary.categories)
    end
  end

  describe "stream registry via collector" do
    test "streams are tracked", %{ctx: ctx} do
      streams = StreamRegistry.list_streams(ctx.registry)
      assert "global" in streams
    end
  end

  # ============================================================================
  # Facade API tests — exercise the Arbor.Historian module directly.
  # These use the globally-started historian processes (not the setup ctx).
  # ============================================================================

  describe "facade API" do
    test "streams/0 lists stream IDs" do
      streams = Arbor.Historian.streams()
      assert is_list(streams)
    end

    test "all_streams/0 returns stream metadata map" do
      all = Arbor.Historian.all_streams()
      assert is_map(all)
    end

    test "stats/0 returns combined statistics" do
      stats = Arbor.Historian.stats()
      assert is_map(stats)
      assert Map.has_key?(stats, :stream_count)
      assert Map.has_key?(stats, :total_events)
    end

    test "healthy?/0 returns boolean" do
      result = Arbor.Historian.healthy?()
      assert is_boolean(result)
    end

    test "recent/0 returns entries" do
      {:ok, entries} = Arbor.Historian.recent()
      assert is_list(entries)
    end

    test "query/0 returns entries" do
      {:ok, entries} = Arbor.Historian.query()
      assert is_list(entries)
    end

    test "error_count/0 returns integer" do
      assert is_integer(Arbor.Historian.error_count())
    end

    test "category_distribution/0 returns map" do
      dist = Arbor.Historian.category_distribution()
      assert is_map(dist)
    end

    test "type_distribution/0 returns map" do
      dist = Arbor.Historian.type_distribution()
      assert is_map(dist)
    end

    test "for_agent/1 returns entries for nonexistent agent" do
      {:ok, list} = Arbor.Historian.for_agent("nonexistent")
      assert is_list(list)
    end

    test "for_category/1 returns entries for category" do
      {:ok, list} = Arbor.Historian.for_category(:activity)
      assert is_list(list)
    end

    test "for_session/1 returns entries for nonexistent session" do
      {:ok, list} = Arbor.Historian.for_session("nonexistent")
      assert is_list(list)
    end

    test "for_correlation/1 returns entries for nonexistent correlation" do
      {:ok, list} = Arbor.Historian.for_correlation("nonexistent")
      assert is_list(list)
    end

    test "find_by_signal_id/1 returns error for nonexistent signal" do
      assert {:error, :not_found} = Arbor.Historian.find_by_signal_id("nonexistent")
    end

    test "count_by_category/1 returns integer" do
      count = Arbor.Historian.count_by_category(:activity)
      assert is_integer(count)
    end

    test "agent_activity/1 returns map for nonexistent agent" do
      result = Arbor.Historian.agent_activity("nonexistent")
      assert is_map(result)
    end

    test "stream_info/1 returns ok or not_found" do
      result = Arbor.Historian.stream_info("global")
      assert match?({:ok, %{}}, result) or match?({:error, :not_found}, result)
    end

    test "reconstruct/1 returns entries for span" do
      span = Span.last_hours(1, [])
      {:ok, list} = Arbor.Historian.reconstruct(span)
      assert is_list(list)
    end

    test "causality_chain/1 returns entries for nonexistent signal" do
      {:ok, list} = Arbor.Historian.causality_chain("nonexistent")
      assert is_list(list)
    end

    test "timeline_summary/1 returns map for span" do
      span = Span.last_hours(1, [])
      summary = Arbor.Historian.timeline_summary(span)
      assert is_map(summary)
    end
  end

  describe "facade contract callbacks" do
    test "read_recent_history_entries/1" do
      {:ok, entries} = Arbor.Historian.read_recent_history_entries([])
      assert is_list(entries)
    end

    test "query_history_entries_with_filters/1" do
      {:ok, entries} = Arbor.Historian.query_history_entries_with_filters([])
      assert is_list(entries)
    end

    test "count_history_entries_by_category/2" do
      count = Arbor.Historian.count_history_entries_by_category(:activity, [])
      assert is_integer(count)
    end

    test "count_error_history_entries/1" do
      count = Arbor.Historian.count_error_history_entries([])
      assert is_integer(count)
    end

    test "read_category_distribution/1" do
      dist = Arbor.Historian.read_category_distribution([])
      assert is_map(dist)
    end

    test "read_type_distribution/1" do
      dist = Arbor.Historian.read_type_distribution([])
      assert is_map(dist)
    end

    test "list_all_stream_ids/0" do
      streams = Arbor.Historian.list_all_stream_ids()
      assert is_list(streams)
    end

    test "read_all_streams_metadata/0" do
      meta = Arbor.Historian.read_all_streams_metadata()
      assert is_map(meta)
    end

    test "read_historian_stats/0" do
      stats = Arbor.Historian.read_historian_stats()
      assert is_map(stats)
    end

    test "read_history_entries_for_agent/2 returns entries" do
      {:ok, list} = Arbor.Historian.read_history_entries_for_agent("agent_01", [])
      assert is_list(list)
    end

    test "read_history_entries_for_category/2 returns entries" do
      {:ok, list} = Arbor.Historian.read_history_entries_for_category(:activity, [])
      assert is_list(list)
    end

    test "read_history_entries_for_session/2 returns entries" do
      {:ok, list} = Arbor.Historian.read_history_entries_for_session("sess_99", [])
      assert is_list(list)
    end

    test "read_history_entries_for_correlation/2 returns entries" do
      {:ok, list} = Arbor.Historian.read_history_entries_for_correlation("corr_x", [])
      assert is_list(list)
    end

    test "find_history_entry_by_signal_id/2 returns not_found for nonexistent" do
      assert {:error, :not_found} = Arbor.Historian.find_history_entry_by_signal_id("nonexistent", [])
    end

    test "read_agent_activity_summary/2 returns map" do
      result = Arbor.Historian.read_agent_activity_summary("agent_01", [])
      assert is_map(result)
    end

    test "reconstruct_timeline_for_span/2 returns entries" do
      span = Span.last_hours(1, [])
      {:ok, list} = Arbor.Historian.reconstruct_timeline_for_span(span, [])
      assert is_list(list)
    end

    test "read_timeline_for_agent/4 returns entries" do
      now = DateTime.utc_now()
      {:ok, list} = Arbor.Historian.read_timeline_for_agent("agent_01", now, now, [])
      assert is_list(list)
    end

    test "read_causality_chain_for_signal/2 returns entries" do
      {:ok, list} = Arbor.Historian.read_causality_chain_for_signal("nonexistent", [])
      assert is_list(list)
    end

    test "read_timeline_summary_for_span/2 returns map" do
      span = Span.last_hours(1, [])
      summary = Arbor.Historian.read_timeline_summary_for_span(span, [])
      assert is_map(summary)
    end

    test "read_stream_info_by_id/1 returns ok or not_found" do
      result = Arbor.Historian.read_stream_info_by_id("global")
      assert match?({:ok, %{}}, result) or match?({:error, :not_found}, result)
    end
  end
end
