defmodule Arbor.Web.HelpersTest do
  use ExUnit.Case, async: true

  alias Arbor.Web.Helpers

  describe "format_relative_time/1" do
    test "returns 'never' for nil" do
      assert Helpers.format_relative_time(nil) == "never"
    end

    test "returns 'just now' for recent DateTime" do
      now = DateTime.utc_now()
      assert Helpers.format_relative_time(now) == "just now"
    end

    test "returns seconds ago" do
      dt = DateTime.add(DateTime.utc_now(), -30, :second)
      assert Helpers.format_relative_time(dt) == "30 seconds ago"
    end

    test "returns minutes ago" do
      dt = DateTime.add(DateTime.utc_now(), -180, :second)
      assert Helpers.format_relative_time(dt) == "3 minutes ago"
    end

    test "returns '1 minute ago'" do
      dt = DateTime.add(DateTime.utc_now(), -90, :second)
      assert Helpers.format_relative_time(dt) == "1 minute ago"
    end

    test "returns hours ago" do
      dt = DateTime.add(DateTime.utc_now(), -7200, :second)
      result = Helpers.format_relative_time(dt)
      assert result == "2 hours ago"
    end

    test "returns '1 hour ago'" do
      dt = DateTime.add(DateTime.utc_now(), -3600, :second)
      assert Helpers.format_relative_time(dt) == "1 hour ago"
    end

    test "returns days ago" do
      dt = DateTime.add(DateTime.utc_now(), -259_200, :second)
      assert Helpers.format_relative_time(dt) == "3 days ago"
    end

    test "returns '1 day ago'" do
      dt = DateTime.add(DateTime.utc_now(), -86_400, :second)
      assert Helpers.format_relative_time(dt) == "1 day ago"
    end

    test "works with NaiveDateTime" do
      ndt = NaiveDateTime.utc_now()
      assert Helpers.format_relative_time(ndt) == "just now"
    end
  end

  describe "format_timestamp/1" do
    test "returns '-' for nil" do
      assert Helpers.format_timestamp(nil) == "-"
    end

    test "formats DateTime" do
      dt = ~U[2026-01-27 14:30:05Z]
      assert Helpers.format_timestamp(dt) == "2026-01-27 14:30:05"
    end

    test "formats NaiveDateTime" do
      ndt = ~N[2026-01-27 14:30:05]
      assert Helpers.format_timestamp(ndt) == "2026-01-27 14:30:05"
    end
  end

  describe "truncate/2" do
    test "returns empty string for nil" do
      assert Helpers.truncate(nil, 10) == ""
    end

    test "returns string unchanged if shorter than limit" do
      assert Helpers.truncate("Hi", 10) == "Hi"
    end

    test "returns string unchanged if exactly at limit" do
      assert Helpers.truncate("Hello", 5) == "Hello"
    end

    test "truncates with ellipsis" do
      assert Helpers.truncate("Hello, world!", 8) == "Hello..."
    end

    test "handles short limits" do
      assert Helpers.truncate("Hello", 2) == "He"
    end

    test "handles length of 4" do
      assert Helpers.truncate("Hello, world!", 4) == "H..."
    end
  end

  describe "status_class/1" do
    test "maps status atoms to CSS classes" do
      assert Helpers.status_class(:running) == "aw-status-running"
      assert Helpers.status_class(:failed) == "aw-status-failed"
      assert Helpers.status_class(:pending) == "aw-status-pending"
    end
  end

  describe "category_class/1" do
    test "maps category atoms to CSS classes" do
      assert Helpers.category_class(:consensus) == "aw-cat-consensus"
      assert Helpers.category_class(:security) == "aw-cat-security"
    end
  end

  describe "pluralize/2,3" do
    test "singular for count of 1" do
      assert Helpers.pluralize(1, "event") == "1 event"
    end

    test "plural for count of 0" do
      assert Helpers.pluralize(0, "event") == "0 events"
    end

    test "plural for count > 1" do
      assert Helpers.pluralize(3, "event") == "3 events"
    end

    test "custom plural form" do
      assert Helpers.pluralize(2, "status", "statuses") == "2 statuses"
    end

    test "singular ignores custom plural" do
      assert Helpers.pluralize(1, "status", "statuses") == "1 status"
    end
  end
end
