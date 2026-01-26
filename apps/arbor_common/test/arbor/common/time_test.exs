defmodule Arbor.Common.TimeTest do
  use ExUnit.Case, async: true

  alias Arbor.Common.Time

  describe "relative/1" do
    test "returns empty string for nil" do
      assert Time.relative(nil) == ""
    end

    test "returns 'just now' for times less than 60 seconds ago" do
      now = DateTime.utc_now()
      assert Time.relative(now) == "just now"

      thirty_seconds_ago = DateTime.add(now, -30, :second)
      assert Time.relative(thirty_seconds_ago) == "just now"
    end

    test "returns minutes ago for times less than an hour" do
      now = DateTime.utc_now()

      five_minutes_ago = DateTime.add(now, -300, :second)
      assert Time.relative(five_minutes_ago) == "5m ago"

      thirty_minutes_ago = DateTime.add(now, -1800, :second)
      assert Time.relative(thirty_minutes_ago) == "30m ago"
    end

    test "returns hours ago for times less than a day" do
      now = DateTime.utc_now()

      two_hours_ago = DateTime.add(now, -7200, :second)
      assert Time.relative(two_hours_ago) == "2h ago"

      twelve_hours_ago = DateTime.add(now, -43_200, :second)
      assert Time.relative(twelve_hours_ago) == "12h ago"
    end

    test "returns days ago for times more than a day" do
      now = DateTime.utc_now()

      two_days_ago = DateTime.add(now, -172_800, :second)
      assert Time.relative(two_days_ago) == "2d ago"
    end

    test "handles future times" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      assert Time.relative(future) == "in the future"
    end
  end

  describe "datetime/1" do
    test "formats DateTime correctly" do
      dt = ~U[2026-01-26 17:30:45Z]
      assert Time.datetime(dt) == "2026-01-26 17:30:45"
    end

    test "formats NaiveDateTime correctly" do
      dt = ~N[2026-01-26 17:30:45]
      assert Time.datetime(dt) == "2026-01-26 17:30:45"
    end

    test "returns dash for nil" do
      assert Time.datetime(nil) == "-"
    end
  end

  describe "time/1" do
    test "formats time correctly" do
      dt = ~U[2026-01-26 17:30:45Z]
      assert Time.time(dt) == "17:30:45"
    end

    test "returns empty string for nil" do
      assert Time.time(nil) == ""
    end
  end

  describe "event/1" do
    test "returns relative time for recent events" do
      now = DateTime.utc_now()
      assert Time.event(now) == "just now"

      one_hour_ago = DateTime.add(now, -3600, :second)
      assert Time.event(one_hour_ago) == "1h ago"
    end

    test "returns calendar format for old events" do
      old = DateTime.add(DateTime.utc_now(), -172_800, :second)
      result = Time.event(old)
      assert result =~ ~r/\d{2}\/\d{2} \d{2}:\d{2}/
    end

    test "returns empty string for nil" do
      assert Time.event(nil) == ""
    end
  end

  describe "duration_ms/1" do
    test "formats sub-minute durations" do
      assert Time.duration_ms(500) == "0.5s"
      assert Time.duration_ms(1500) == "1.5s"
      assert Time.duration_ms(45_000) == "45.0s"
    end

    test "formats minute durations" do
      assert Time.duration_ms(60_000) == "1m"
      assert Time.duration_ms(65_000) == "1m 5s"
      assert Time.duration_ms(125_000) == "2m 5s"
    end

    test "formats hour durations" do
      assert Time.duration_ms(3_600_000) == "1h"
      assert Time.duration_ms(3_665_000) == "1h 1m"
      assert Time.duration_ms(7_320_000) == "2h 2m"
    end

    test "returns dash for invalid input" do
      assert Time.duration_ms(-1) == "-"
      assert Time.duration_ms("invalid") == "-"
    end
  end
end
