defmodule Arbor.Common.TemporalGroupingTest do
  use ExUnit.Case, async: true

  alias Arbor.Common.TemporalGrouping

  @moduletag :fast

  # Fixed reference time for deterministic tests
  @now ~U[2026-02-22 14:30:00Z]

  # ============================================================================
  # classify_bucket/2
  # ============================================================================

  describe "classify_bucket/2" do
    test "classifies same-day as :today" do
      same_day = ~U[2026-02-22 09:00:00Z]
      assert TemporalGrouping.classify_bucket(same_day, @now) == :today
    end

    test "classifies 1 day ago as :yesterday" do
      yesterday = ~U[2026-02-21 18:00:00Z]
      assert TemporalGrouping.classify_bucket(yesterday, @now) == :yesterday
    end

    test "classifies 2-6 days ago as :this_week" do
      two_days = ~U[2026-02-20 12:00:00Z]
      assert TemporalGrouping.classify_bucket(two_days, @now) == :this_week

      six_days = ~U[2026-02-16 12:00:00Z]
      assert TemporalGrouping.classify_bucket(six_days, @now) == :this_week
    end

    test "classifies 7+ days ago as :earlier" do
      week_ago = ~U[2026-02-15 12:00:00Z]
      assert TemporalGrouping.classify_bucket(week_ago, @now) == :earlier

      month_ago = ~U[2026-01-22 12:00:00Z]
      assert TemporalGrouping.classify_bucket(month_ago, @now) == :earlier
    end

    test "classifies future dates as :upcoming" do
      tomorrow = ~U[2026-02-23 09:00:00Z]
      assert TemporalGrouping.classify_bucket(tomorrow, @now) == :upcoming

      next_week = ~U[2026-03-01 09:00:00Z]
      assert TemporalGrouping.classify_bucket(next_week, @now) == :upcoming
    end

    test "classifies nil as :today" do
      assert TemporalGrouping.classify_bucket(nil, @now) == :today
    end

    test "handles Date (not just DateTime)" do
      yesterday_date = ~D[2026-02-21]
      assert TemporalGrouping.classify_bucket(yesterday_date, @now) == :yesterday
    end

    test "midnight boundary — end of yesterday vs start of today" do
      # Just before midnight still yesterday
      late_yesterday = ~U[2026-02-21 23:59:59Z]
      assert TemporalGrouping.classify_bucket(late_yesterday, @now) == :yesterday

      # Midnight of today is today
      start_of_today = ~U[2026-02-22 00:00:00Z]
      assert TemporalGrouping.classify_bucket(start_of_today, @now) == :today
    end
  end

  # ============================================================================
  # group_by_time/3
  # ============================================================================

  describe "group_by_time/3" do
    test "groups items into correct buckets" do
      items = [
        %{content: "today", ts: ~U[2026-02-22 10:00:00Z], ref: nil},
        %{content: "yesterday", ts: ~U[2026-02-21 15:00:00Z], ref: nil},
        %{content: "week", ts: ~U[2026-02-18 12:00:00Z], ref: nil}
      ]

      extract = fn item -> {item.ts, item.ref} end
      grouped = TemporalGrouping.group_by_time(items, extract, now: @now)

      assert Keyword.keys(grouped) == [:today, :yesterday, :this_week]
      assert length(grouped[:today]) == 1
      assert length(grouped[:yesterday]) == 1
      assert length(grouped[:this_week]) == 1
    end

    test "uses referenced_date for bucketing when present" do
      # Item observed today but refers to yesterday
      items = [
        %{content: "refers to past", ts: ~U[2026-02-22 10:00:00Z], ref: ~U[2026-02-21 09:00:00Z]}
      ]

      extract = fn item -> {item.ts, item.ref} end
      grouped = TemporalGrouping.group_by_time(items, extract, now: @now)

      # Should be in yesterday bucket (by referenced_date), not today
      assert Keyword.keys(grouped) == [:yesterday]
    end

    test "omits empty buckets" do
      items = [
        %{content: "today only", ts: ~U[2026-02-22 10:00:00Z], ref: nil}
      ]

      extract = fn item -> {item.ts, item.ref} end
      grouped = TemporalGrouping.group_by_time(items, extract, now: @now)

      assert Keyword.keys(grouped) == [:today]
    end

    test "sorts items within bucket newest-first" do
      items = [
        %{content: "early", ts: ~U[2026-02-22 08:00:00Z], ref: nil},
        %{content: "late", ts: ~U[2026-02-22 16:00:00Z], ref: nil},
        %{content: "mid", ts: ~U[2026-02-22 12:00:00Z], ref: nil}
      ]

      extract = fn item -> {item.ts, item.ref} end
      grouped = TemporalGrouping.group_by_time(items, extract, now: @now)

      contents = Enum.map(grouped[:today], & &1.content)
      assert contents == ["late", "mid", "early"]
    end

    test "returns empty keyword list for empty input" do
      grouped = TemporalGrouping.group_by_time([], fn _ -> {nil, nil} end, now: @now)
      assert grouped == []
    end

    test "bucket order is preserved" do
      items = [
        %{content: "earlier", ts: ~U[2026-02-10 10:00:00Z], ref: nil},
        %{content: "upcoming", ts: ~U[2026-02-22 10:00:00Z], ref: ~U[2026-02-25 10:00:00Z]},
        %{content: "today", ts: ~U[2026-02-22 10:00:00Z], ref: nil},
        %{content: "yesterday", ts: ~U[2026-02-21 10:00:00Z], ref: nil}
      ]

      extract = fn item -> {item.ts, item.ref} end
      grouped = TemporalGrouping.group_by_time(items, extract, now: @now)

      assert Keyword.keys(grouped) == [:upcoming, :today, :yesterday, :earlier]
    end
  end

  # ============================================================================
  # format_grouped/4
  # ============================================================================

  describe "format_grouped/4" do
    test "renders grouped items with headers and annotations" do
      items = [
        %{content: "morning task", ts: ~U[2026-02-22 09:15:00Z], ref: nil},
        %{content: "afternoon task", ts: ~U[2026-02-22 14:30:00Z], ref: nil}
      ]

      extract = fn item -> {item.ts, item.ref} end
      grouped = TemporalGrouping.group_by_time(items, extract, now: @now)

      format_fn = fn item, annotation ->
        if annotation == "", do: "- #{item.content}", else: "- #{annotation} #{item.content}"
      end

      output = TemporalGrouping.format_grouped(grouped, extract, format_fn, now: @now)

      assert output =~ "### Today"
      assert output =~ "[14:30] afternoon task"
      assert output =~ "[09:15] morning task"
    end

    test "includes referenced_date annotation when different" do
      items = [
        %{content: "deploy note", ts: ~U[2026-02-22 10:00:00Z], ref: ~U[2026-02-20 10:00:00Z]}
      ]

      extract = fn item -> {item.ts, item.ref} end
      grouped = TemporalGrouping.group_by_time(items, extract, now: @now)

      format_fn = fn item, annotation ->
        "- #{annotation} #{item.content}"
      end

      output = TemporalGrouping.format_grouped(grouped, extract, format_fn, now: @now)

      assert output =~ "refers to Feb 20"
    end
  end

  # ============================================================================
  # time_annotation/3
  # ============================================================================

  describe "time_annotation/3" do
    test "returns [HH:MM] for today" do
      obs = ~U[2026-02-22 14:30:00Z]
      assert TemporalGrouping.time_annotation(obs, nil, @now) == "[14:30]"
    end

    test "returns [Feb 21 15:00] for other days" do
      obs = ~U[2026-02-21 15:00:00Z]
      assert TemporalGrouping.time_annotation(obs, nil, @now) == "[Feb 21 15:00]"
    end

    test "appends (refers to ...) when referenced_date differs" do
      obs = ~U[2026-02-22 10:00:00Z]
      ref = ~U[2026-02-19 10:00:00Z]
      result = TemporalGrouping.time_annotation(obs, ref, @now)

      assert result =~ "[10:00]"
      assert result =~ "(refers to Feb 19)"
    end

    test "no reference annotation when same day" do
      obs = ~U[2026-02-22 10:00:00Z]
      ref = ~U[2026-02-22 15:00:00Z]
      result = TemporalGrouping.time_annotation(obs, ref, @now)

      assert result == "[10:00]"
      refute result =~ "refers to"
    end

    test "handles nil observation with referenced_date" do
      ref = ~U[2026-02-19 10:00:00Z]
      result = TemporalGrouping.time_annotation(nil, ref, @now)

      assert result == "(refers to Feb 19)"
    end

    test "handles both nil" do
      assert TemporalGrouping.time_annotation(nil, nil, @now) == ""
    end
  end
end
