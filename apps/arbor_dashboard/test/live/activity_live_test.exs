defmodule Arbor.Dashboard.Live.ActivityLiveTest do
  use Arbor.Dashboard.ConnCase, async: true

  describe "ActivityLive" do
    test "renders activity dashboard header", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/activity")

      assert html =~ "Activity"
      assert html =~ "Unified activity feed"
    end

    test "shows pause button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/activity")

      assert html =~ "Pause"
    end

    test "shows stat cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/activity")

      assert html =~ "Events"
      assert html =~ "Categories"
      assert html =~ "Agents"
    end

    test "shows category filter bar", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/activity")

      assert html =~ "aw-filter-bar"
      assert html =~ "All"
    end

    test "shows time filter buttons", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/activity")

      assert html =~ "All time"
      assert html =~ "Last hour"
      assert html =~ "Today"
    end

    test "toggle pause changes button text", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/activity")

      html = render_click(view, "toggle-pause")
      assert html =~ "Resume"

      html = render_click(view, "toggle-pause")
      assert html =~ "Pause"
    end

    test "clear filters button present", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/activity")

      assert html =~ "Clear filters"
    end
  end
end
