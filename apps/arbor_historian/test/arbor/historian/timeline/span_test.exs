defmodule Arbor.Historian.Timeline.SpanTest do
  use ExUnit.Case, async: true

  alias Arbor.Historian.Timeline.Span

  describe "new/1" do
    test "creates a span with required fields" do
      from = ~U[2026-01-01 00:00:00Z]
      to = ~U[2026-01-02 00:00:00Z]

      span = Span.new(from: from, to: to)

      assert span.from == from
      assert span.to == to
      assert span.streams == []
      assert span.categories == []
      assert span.types == []
      assert span.agent_id == nil
      assert span.correlation_id == nil
    end

    test "creates a span with all options" do
      span =
        Span.new(
          from: ~U[2026-01-01 00:00:00Z],
          to: ~U[2026-01-02 00:00:00Z],
          streams: ["global", "agent:a1"],
          categories: [:activity, :security],
          types: [:agent_started],
          agent_id: "a1",
          correlation_id: "corr_1"
        )

      assert span.streams == ["global", "agent:a1"]
      assert span.categories == [:activity, :security]
      assert span.types == [:agent_started]
      assert span.agent_id == "a1"
      assert span.correlation_id == "corr_1"
    end

    test "raises on missing required fields" do
      assert_raise KeyError, fn -> Span.new(from: ~U[2026-01-01 00:00:00Z]) end
      assert_raise KeyError, fn -> Span.new(to: ~U[2026-01-01 00:00:00Z]) end
    end
  end

  describe "last_minutes/2" do
    test "creates a span covering recent minutes" do
      span = Span.last_minutes(30)

      assert DateTime.diff(span.to, span.from, :second) == 30 * 60
      assert DateTime.diff(DateTime.utc_now(), span.to, :second) < 2
    end

    test "accepts additional options" do
      span = Span.last_minutes(10, categories: [:activity])

      assert span.categories == [:activity]
      assert DateTime.diff(span.to, span.from, :second) == 10 * 60
    end
  end

  describe "last_hours/2" do
    test "creates a span covering recent hours" do
      span = Span.last_hours(2)

      assert DateTime.diff(span.to, span.from, :second) == 2 * 60 * 60
    end
  end

  describe "contains?/2" do
    test "returns true when datetime is within span" do
      span = Span.new(from: ~U[2026-01-01 00:00:00Z], to: ~U[2026-01-02 00:00:00Z])

      assert Span.contains?(span, ~U[2026-01-01 12:00:00Z])
    end

    test "returns true on boundary" do
      span = Span.new(from: ~U[2026-01-01 00:00:00Z], to: ~U[2026-01-02 00:00:00Z])

      assert Span.contains?(span, ~U[2026-01-01 00:00:00Z])
      assert Span.contains?(span, ~U[2026-01-02 00:00:00Z])
    end

    test "returns false when datetime is outside span" do
      span = Span.new(from: ~U[2026-01-01 00:00:00Z], to: ~U[2026-01-02 00:00:00Z])

      refute Span.contains?(span, ~U[2025-12-31 00:00:00Z])
      refute Span.contains?(span, ~U[2026-01-03 00:00:00Z])
    end
  end

  describe "duration_seconds/1" do
    test "returns duration in seconds" do
      span = Span.new(from: ~U[2026-01-01 00:00:00Z], to: ~U[2026-01-01 01:30:00Z])

      assert Span.duration_seconds(span) == 5400
    end
  end
end
