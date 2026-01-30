defmodule Arbor.Historian.QueryEngine.AggregatorTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Historian.HistoryEntry
  alias Arbor.Historian.QueryEngine.Aggregator
  alias Arbor.Historian.TestHelpers

  setup do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    ctx = TestHelpers.start_test_historian(:"agg_#{System.unique_integer([:positive])}")

    signals = [
      TestHelpers.build_signal(category: :activity, type: :agent_started),
      TestHelpers.build_signal(category: :activity, type: :task_completed),
      TestHelpers.build_signal(category: :security, type: :authorization),
      TestHelpers.build_signal(category: :logs, type: :error),
      TestHelpers.build_signal(category: :logs, type: :warn),
      TestHelpers.build_signal(category: :logs, type: :info)
    ]

    for s <- signals, do: TestHelpers.collect_signal(ctx, s)

    %{ctx: ctx}
  end

  describe "count_by_category/2" do
    test "counts entries for a category", %{ctx: ctx} do
      assert Aggregator.count_by_category(:activity, event_log: ctx.event_log) == 2
      assert Aggregator.count_by_category(:security, event_log: ctx.event_log) == 1
      assert Aggregator.count_by_category(:logs, event_log: ctx.event_log) == 3
    end

    test "returns 0 for unknown category", %{ctx: ctx} do
      assert Aggregator.count_by_category(:nonexistent, event_log: ctx.event_log) == 0
    end
  end

  describe "error_count/1" do
    test "counts error and warn entries", %{ctx: ctx} do
      assert Aggregator.error_count(event_log: ctx.event_log) == 2
    end

    test "returns 0 when no errors or warnings exist" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      ctx = TestHelpers.start_test_historian(:"agg_no_errors_#{System.unique_integer([:positive])}")

      signals = [
        TestHelpers.build_signal(category: :activity, type: :agent_started),
        TestHelpers.build_signal(category: :security, type: :authorization),
        TestHelpers.build_signal(category: :logs, type: :info)
      ]

      for s <- signals, do: TestHelpers.collect_signal(ctx, s)

      assert Aggregator.error_count(event_log: ctx.event_log) == 0
    end
  end

  describe "category_distribution/1" do
    test "returns frequency map of categories", %{ctx: ctx} do
      dist = Aggregator.category_distribution(event_log: ctx.event_log)

      assert dist[:activity] == 2
      assert dist[:security] == 1
      assert dist[:logs] == 3
    end
  end

  describe "type_distribution/1" do
    test "returns frequency map of types", %{ctx: ctx} do
      dist = Aggregator.type_distribution(event_log: ctx.event_log)

      assert dist[:agent_started] == 1
      assert dist[:task_completed] == 1
      assert dist[:error] == 1
      assert dist[:warn] == 1
      assert dist[:info] == 1
    end

    test "returns frequency map with various types" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      ctx = TestHelpers.start_test_historian(:"agg_types_#{System.unique_integer([:positive])}")

      signals = [
        TestHelpers.build_signal(category: :activity, type: :agent_started),
        TestHelpers.build_signal(category: :activity, type: :agent_started),
        TestHelpers.build_signal(category: :activity, type: :agent_started),
        TestHelpers.build_signal(category: :security, type: :authorization),
        TestHelpers.build_signal(category: :security, type: :authorization)
      ]

      for s <- signals, do: TestHelpers.collect_signal(ctx, s)

      dist = Aggregator.type_distribution(event_log: ctx.event_log)
      assert dist[:agent_started] == 3
      assert dist[:authorization] == 2
    end
  end

  describe "agent_activity/2" do
    test "returns activity summary for an agent", %{ctx: ctx} do
      # Add agent-specific signals
      agent_signals = [
        TestHelpers.build_agent_signal("agg_agent_1", category: :activity, type: :agent_started),
        TestHelpers.build_agent_signal("agg_agent_1", category: :activity, type: :task_completed)
      ]

      for s <- agent_signals, do: TestHelpers.collect_signal(ctx, s)

      summary = Aggregator.agent_activity("agg_agent_1", event_log: ctx.event_log)
      assert summary.total == 2
      assert summary.categories[:activity] == 2
      assert is_struct(summary.first, DateTime)
      assert is_struct(summary.last, DateTime)
    end

    test "returns empty summary for agent with no entries", %{ctx: ctx} do
      summary = Aggregator.agent_activity("nonexistent_agent", event_log: ctx.event_log)
      assert summary.total == 0
      assert summary.categories == %{}
      assert summary.types == %{}
      assert summary.first == nil
      assert summary.last == nil
      assert summary.errors == 0
    end
  end

  describe "build_summary/1" do
    test "builds summary from entries" do
      now = DateTime.utc_now()
      earlier = DateTime.add(now, -3600, :second)

      entries = [
        %HistoryEntry{
          id: "h1",
          signal_id: "s1",
          stream_id: "global",
          category: :activity,
          type: :agent_started,
          timestamp: earlier
        },
        %HistoryEntry{
          id: "h2",
          signal_id: "s2",
          stream_id: "global",
          category: :logs,
          type: :error,
          timestamp: now
        }
      ]

      summary = Aggregator.build_summary(entries)

      assert summary.total == 2
      assert summary.categories == %{activity: 1, logs: 1}
      assert summary.types == %{agent_started: 1, error: 1}
      assert summary.first == earlier
      assert summary.last == now
      assert summary.errors == 1
    end

    test "handles empty list" do
      summary = Aggregator.build_summary([])

      assert summary.total == 0
      assert summary.categories == %{}
      assert summary.first == nil
      assert summary.last == nil
    end

    test "builds summary from a single entry" do
      now = DateTime.utc_now()

      entries = [
        %HistoryEntry{
          id: "h_single",
          signal_id: "s_single",
          stream_id: "global",
          category: :security,
          type: :authorization,
          timestamp: now
        }
      ]

      summary = Aggregator.build_summary(entries)

      assert summary.total == 1
      assert summary.categories == %{security: 1}
      assert summary.types == %{authorization: 1}
      assert summary.first == now
      assert summary.last == now
      assert summary.errors == 0
    end

    test "counts errors and warnings correctly in summary" do
      now = DateTime.utc_now()

      entries = [
        %HistoryEntry{
          id: "h_e1",
          signal_id: "s_e1",
          stream_id: "global",
          category: :logs,
          type: :error,
          timestamp: now
        },
        %HistoryEntry{
          id: "h_e2",
          signal_id: "s_e2",
          stream_id: "global",
          category: :logs,
          type: :warn,
          timestamp: now
        },
        %HistoryEntry{
          id: "h_e3",
          signal_id: "s_e3",
          stream_id: "global",
          category: :logs,
          type: :info,
          timestamp: now
        },
        %HistoryEntry{
          id: "h_e4",
          signal_id: "s_e4",
          stream_id: "global",
          category: :activity,
          type: :agent_started,
          timestamp: now
        }
      ]

      summary = Aggregator.build_summary(entries)
      assert summary.total == 4
      assert summary.errors == 2
    end
  end
end
