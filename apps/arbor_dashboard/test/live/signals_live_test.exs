defmodule Arbor.Dashboard.Live.SignalsLiveTest do
  use Arbor.Dashboard.ConnCase, async: true

  describe "SignalsLive" do
    test "renders signal dashboard header", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/signals")

      assert html =~ "Signals"
      assert html =~ "Real-time signal stream"
    end

    test "shows pause button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/signals")

      assert html =~ "Pause"
    end

    test "shows stat cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/signals")

      assert html =~ "Signals stored"
      assert html =~ "Subscriptions"
      assert html =~ "System health"
    end

    test "shows filter bar with All button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/signals")

      assert html =~ "aw-filter-bar"
      assert html =~ "All"
    end

    test "shows stream container", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/signals")

      assert html =~ "signals-stream"
    end

    test "toggle pause changes button text", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/signals")

      html = render_click(view, "toggle-pause")
      assert html =~ "Resume"

      html = render_click(view, "toggle-pause")
      assert html =~ "Pause"
    end
  end
end
