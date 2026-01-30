defmodule Arbor.Historian.TimelineTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Historian.TestHelpers
  alias Arbor.Historian.Timeline
  alias Arbor.Historian.Timeline.Span

  setup do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
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

    test "reconstruct with explicit streams list", %{ctx: ctx, t1: t1, now: now} do
      from = DateTime.add(t1, -60, :second)
      span = Span.new(from: from, to: now, streams: ["global"])

      {:ok, entries} = Timeline.reconstruct(span, event_log: ctx.event_log)
      assert length(entries) == 3
    end

    test "reconstruct with max_results truncates", %{ctx: ctx, t1: t1, now: now} do
      from = DateTime.add(t1, -60, :second)
      span = Span.new(from: from, to: now)

      {:ok, entries} = Timeline.reconstruct(span, event_log: ctx.event_log, max_results: 2)
      assert length(entries) == 2
    end

    test "reconstruct with categories span uses category streams", %{ctx: ctx, t1: t1, now: now} do
      from = DateTime.add(t1, -60, :second)
      span = Span.new(from: from, to: now, categories: [:activity])

      {:ok, entries} = Timeline.reconstruct(span, event_log: ctx.event_log)
      assert length(entries) == 2
      assert Enum.all?(entries, &(&1.category == :activity))
    end
  end

  describe "determine_streams via reconstruct" do
    test "uses correlation_id stream", %{ctx: ctx, now: now} do
      # Add a signal with a known correlation_id
      TestHelpers.collect_signal(
        ctx,
        TestHelpers.build_signal(
          category: :activity,
          type: :agent_started,
          time: DateTime.add(now, -50, :second),
          id: "sig_corr_1",
          correlation_id: "corr_determine"
        )
      )

      from = DateTime.add(now, -3600, :second)
      span = Span.new(from: from, to: now, correlation_id: "corr_determine")

      {:ok, entries} = Timeline.reconstruct(span, event_log: ctx.event_log)
      assert length(entries) == 1
      assert hd(entries).correlation_id == "corr_determine"
    end

    test "uses agent_id stream", %{ctx: ctx, t1: t1, now: now} do
      from = DateTime.add(t1, -60, :second)
      span = Span.new(from: from, to: now, agent_id: "a1")

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

    test "returns empty for agent with no events within range", %{ctx: ctx, now: now} do
      from = DateTime.add(now, -60, :second)

      {:ok, entries} = Timeline.for_agent("nonexistent_agent", from, now, event_log: ctx.event_log)
      assert entries == []
    end

    test "returns timeline for agent within narrow time range", %{ctx: ctx, t1: t1} do
      # Only get the first signal (t1), excluding t2
      from = DateTime.add(t1, -10, :second)
      to = DateTime.add(t1, 10, :second)

      {:ok, entries} = Timeline.for_agent("a1", from, to, event_log: ctx.event_log)
      assert length(entries) == 1
      assert hd(entries).type == :agent_started
    end
  end

  describe "for_correlation/2" do
    test "returns entries for correlation chain", %{ctx: ctx} do
      # Add a correlated signal
      TestHelpers.collect_signal(
        ctx,
        TestHelpers.build_signal(
          category: :activity,
          type: :task_completed,
          id: "sig_for_corr",
          correlation_id: "corr_fc_1"
        )
      )

      {:ok, entries} = Timeline.for_correlation("corr_fc_1", event_log: ctx.event_log)
      assert length(entries) == 1
    end

    test "returns empty for unknown correlation", %{ctx: ctx} do
      {:ok, entries} = Timeline.for_correlation("nonexistent_corr", event_log: ctx.event_log)
      assert entries == []
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

    test "returns single-entry chain for leaf signal", %{ctx: ctx} do
      {:ok, chain} = Timeline.for_causality_chain("sig_3", event_log: ctx.event_log)

      signal_ids = Enum.map(chain, & &1.signal_id)
      # sig_3 has cause_id sig_2, which has cause_id sig_1
      assert "sig_1" in signal_ids
      assert "sig_2" in signal_ids
      assert "sig_3" in signal_ids
    end

    test "handles circular references without infinite loop", %{ctx: ctx} do
      # Create a circular cause chain: A -> B -> A
      TestHelpers.collect_signal(
        ctx,
        TestHelpers.build_signal(
          category: :activity,
          type: :agent_started,
          id: "sig_circ_a",
          cause_id: "sig_circ_b"
        )
      )

      TestHelpers.collect_signal(
        ctx,
        TestHelpers.build_signal(
          category: :activity,
          type: :task_completed,
          id: "sig_circ_b",
          cause_id: "sig_circ_a"
        )
      )

      # Should terminate and not loop forever
      {:ok, chain} = Timeline.for_causality_chain("sig_circ_a", event_log: ctx.event_log)
      assert is_list(chain)
      # Both signals should appear but no duplicates
      signal_ids = Enum.map(chain, & &1.signal_id)
      assert "sig_circ_a" in signal_ids
      assert "sig_circ_b" in signal_ids
      assert length(signal_ids) == length(Enum.uniq(signal_ids))
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

    test "returns summary with first and last timestamps", %{ctx: ctx, t1: t1, now: now} do
      from = DateTime.add(t1, -60, :second)
      span = Span.new(from: from, to: now)

      summary = Timeline.summary(span, event_log: ctx.event_log)

      assert is_struct(summary.first, DateTime)
      assert is_struct(summary.last, DateTime)
      assert DateTime.compare(summary.first, summary.last) in [:lt, :eq]
    end

    test "returns empty summary for empty span", %{ctx: ctx} do
      # A time range that contains no events
      old_from = DateTime.add(DateTime.utc_now(), -7200, :second)
      old_to = DateTime.add(DateTime.utc_now(), -7100, :second)
      span = Span.new(from: old_from, to: old_to)

      summary = Timeline.summary(span, event_log: ctx.event_log)

      assert summary.total == 0
      assert summary.categories == %{}
      assert summary.first == nil
      assert summary.last == nil
    end

    test "summary types map matches entries", %{ctx: ctx, t1: t1, now: now} do
      from = DateTime.add(t1, -60, :second)
      span = Span.new(from: from, to: now)

      summary = Timeline.summary(span, event_log: ctx.event_log)

      assert Map.has_key?(summary, :types)
      assert summary.types[:agent_started] == 1
      assert summary.types[:task_completed] == 1
      assert summary.types[:authorization] == 1
    end
  end
end
