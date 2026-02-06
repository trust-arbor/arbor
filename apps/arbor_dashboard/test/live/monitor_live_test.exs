defmodule Arbor.Dashboard.Live.MonitorLiveTest do
  use Arbor.Dashboard.ConnCase, async: true

  describe "MonitorLive" do
    test "renders monitor dashboard header", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/monitor")

      assert html =~ "BEAM Runtime Monitor"
      assert html =~ "System health and anomaly detection"
    end

    test "shows refresh button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/monitor")

      assert html =~ "Refresh"
    end

    test "shows health status bar", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/monitor")

      assert html =~ "aw-monitor-status-bar"
      assert html =~ "aw-monitor-health-indicator"
    end

    test "shows anomalies section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/monitor")

      assert html =~ "Recent Anomalies"
    end

    test "shows empty state when no skills available", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/monitor")

      # Either shows skill cards or empty state
      assert html =~ "aw-skill-card" or html =~ "No skills available"
    end

    test "refresh event works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/monitor")

      # Should not crash when clicking refresh
      html = render_click(view, "refresh")
      assert html =~ "BEAM Runtime Monitor"
    end
  end
end
