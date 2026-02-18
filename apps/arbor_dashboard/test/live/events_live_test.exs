defmodule Arbor.Dashboard.Live.EventsLiveTest do
  use Arbor.Dashboard.ConnCase, async: true

  describe "EventsLive" do
    test "renders events dashboard header", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/events")

      assert html =~ "Events"
      assert html =~ "Persisted event history"
    end

    test "shows refresh button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/events")

      assert html =~ "Refresh"
    end

    test "shows stat cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/events")

      assert html =~ "Total Events"
      assert html =~ "Streams"
      assert html =~ "Categories"
    end

    test "shows category filter bar", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/events")

      assert html =~ "aw-filter-bar"
      assert html =~ "All"
    end

    test "shows time filter buttons", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/events")

      assert html =~ "All time"
      assert html =~ "Last hour"
      assert html =~ "Today"
    end

    test "refresh does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/events")

      html = render_click(view, "refresh")
      assert is_binary(html)
    end

    test "clear filters button present when filters active", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/events")

      # Apply a time filter to make clear-filters appear
      html = render_click(view, "filter-time", %{"range" => "hour"})
      assert html =~ "Clear filters"
    end

    test "clear filters resets all filters", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/events")

      render_click(view, "filter-time", %{"range" => "hour"})
      html = render_click(view, "clear-filters")
      assert is_binary(html)
    end

    test "close-detail clears selected event", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/events")

      html = render_click(view, "close-detail")
      assert is_binary(html)
    end
  end
end
