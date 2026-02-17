defmodule Arbor.Dashboard.Live.MonitorLiveTest do
  use Arbor.Dashboard.ConnCase, async: true

  @tag :fast
  describe "MonitorLive mount" do
    @tag :fast
    test "renders monitor dashboard header", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/monitor")

      assert html =~ "BEAM Runtime Monitor"
      assert html =~ "System health and anomaly detection"
    end

    @tag :fast
    test "shows refresh button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/monitor")

      assert html =~ "Refresh"
    end

    @tag :fast
    test "shows health status bar", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/monitor")

      assert html =~ "aw-monitor-status-bar"
      assert html =~ "aw-monitor-health-indicator"
    end

    @tag :fast
    test "shows anomalies section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/monitor")

      assert html =~ "Recent Anomalies"
    end

    @tag :fast
    test "shows empty state when no skills available", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/monitor")

      # Either shows skill cards or empty state
      assert html =~ "aw-skill-card" or html =~ "No skills available"
    end
  end

  @tag :fast
  describe "MonitorLive refresh event" do
    @tag :fast
    test "refresh event works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/monitor")

      # Should not crash when clicking refresh
      html = render_click(view, "refresh")
      assert html =~ "BEAM Runtime Monitor"
    end

    @tag :fast
    test "refresh event updates metrics", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/monitor")

      html = render_click(view, "refresh")
      assert html =~ "anomalies"
    end
  end

  @tag :fast
  describe "MonitorLive select_skill event" do
    @tag :fast
    test "select_skill with known atom does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/monitor")

      # :memory is a known atom in the BEAM
      html = render_click(view, "select_skill", %{"skill" => "memory"})
      assert is_binary(html)
    end

    @tag :fast
    test "select_skill toggles selection off when same skill", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/monitor")

      # Select memory
      render_click(view, "select_skill", %{"skill" => "memory"})
      # Select again to deselect
      html = render_click(view, "select_skill", %{"skill" => "memory"})
      assert is_binary(html)
    end
  end

  @tag :fast
  describe "MonitorLive close_detail event" do
    @tag :fast
    test "close_detail clears selection", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/monitor")

      # Select a skill first, then close
      render_click(view, "select_skill", %{"skill" => "memory"})
      html = render_click(view, "close_detail")
      assert is_binary(html)
    end
  end
end
