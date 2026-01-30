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
end
