defmodule Arbor.Historian.TimelineTest do
  use ExUnit.Case, async: true

  alias Arbor.Historian.Timeline
  alias Arbor.Historian.Timeline.Span
  alias Arbor.Historian.TestHelpers

  setup do
    ctx = TestHelpers.start_test_historian(:"timeline_#{System.unique_integer([:positive])}")

    now = DateTime.utc_now()
    t1 = DateTime.add(now, -300, :second)
    t2 = DateTime.add(now, -200, :second)
    t3 = DateTime.add(now, -100, :second)

    signals = [
      TestHelpers.build_agent_signal("a1",
        category: :activity,
        type: :agent_started,
        time: t1,
        id: "sig_1"
      ),
      TestHelpers.build_agent_signal("a1",
        category: :activity,
        type: :task_completed,
        time: t2,
        id: "sig_2",
        cause_id: "sig_1"
      ),
      TestHelpers.build_signal(
        category: :security,
        type: :authorization,
        time: t3,
        id: "sig_3",
        cause_id: "sig_2"
      )
    ]

    for s <- signals, do: TestHelpers.collect_signal(ctx, s)

    %{ctx: ctx, now: now, t1: t1, t2: t2, t3: t3}
  end

  describe "reconstruct/2" do
    test "reconstructs global timeline", %{ctx: ctx, t1: t1, now: now} do
      from = DateTime.add(t1, -60, :second)
      span = Span.new(from: from, to: now)

      {:ok, entries} = Timeline.reconstruct(span, event_log: ctx.event_log)

      # 3 signals but each routed to multiple streams — global stream has all 3
      assert length(entries) == 3
      # Should be in chronological order
      timestamps = Enum.map(entries, & &1.timestamp)
      assert timestamps == Enum.sort(timestamps, DateTime)
    end

    test "filters by categories", %{ctx: ctx, t1: t1, now: now} do
      from = DateTime.add(t1, -60, :second)
      span = Span.new(from: from, to: now, categories: [:security])

      {:ok, entries} = Timeline.reconstruct(span, event_log: ctx.event_log)

      assert length(entries) == 1
      assert hd(entries).category == :security
    end

    test "filters by types", %{ctx: ctx, t1: t1, now: now} do
      from = DateTime.add(t1, -60, :second)
      span = Span.new(from: from, to: now, types: [:agent_started])

      {:ok, entries} = Timeline.reconstruct(span, event_log: ctx.event_log)

      assert length(entries) == 1
      assert hd(entries).type == :agent_started
    end

    test "filters by time range", %{ctx: ctx, t1: t1, t2: t2} do
      span = Span.new(from: DateTime.add(t1, -10, :second), to: DateTime.add(t2, 10, :second))

      {:ok, entries} = Timeline.reconstruct(span, event_log: ctx.event_log)

      assert length(entries) == 2
    end
  end

  describe "for_agent/4" do
    test "returns timeline for a specific agent", %{ctx: ctx, t1: t1, now: now} do
      from = DateTime.add(t1, -60, :second)

      {:ok, entries} = Timeline.for_agent("a1", from, now, event_log: ctx.event_log)

      assert length(entries) == 2
      assert Enum.all?(entries, &(&1.category == :activity))
    end
  end

  describe "for_causality_chain/2" do
    test "follows causality chain forward from root", %{ctx: ctx} do
      {:ok, chain} = Timeline.for_causality_chain("sig_1", event_log: ctx.event_log)

      signal_ids = Enum.map(chain, & &1.signal_id)
      assert "sig_1" in signal_ids
      assert "sig_2" in signal_ids
      assert "sig_3" in signal_ids
    end

    test "follows causality chain from middle", %{ctx: ctx} do
      {:ok, chain} = Timeline.for_causality_chain("sig_2", event_log: ctx.event_log)

      signal_ids = Enum.map(chain, & &1.signal_id)
      assert "sig_1" in signal_ids
      assert "sig_2" in signal_ids
      assert "sig_3" in signal_ids
    end

    test "returns empty for unknown signal", %{ctx: ctx} do
      {:ok, chain} = Timeline.for_causality_chain("sig_unknown", event_log: ctx.event_log)
      assert chain == []
    end
  end

  describe "summary/2" do
    test "returns aggregate statistics", %{ctx: ctx, t1: t1, now: now} do
      from = DateTime.add(t1, -60, :second)
      span = Span.new(from: from, to: now)

      summary = Timeline.summary(span, event_log: ctx.event_log)

      assert summary.total == 3
      assert summary.categories[:activity] == 2
      assert summary.categories[:security] == 1
      assert summary.errors == 0
    end
  end
end
