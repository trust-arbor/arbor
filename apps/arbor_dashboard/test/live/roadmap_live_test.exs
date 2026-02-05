defmodule Arbor.Dashboard.Live.RoadmapLiveTest do
  use Arbor.Dashboard.ConnCase, async: true

  describe "RoadmapLive" do
    test "renders roadmap dashboard header", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/roadmap")

      assert html =~ "Roadmap"
      assert html =~ "SDLC pipeline"
    end

    test "shows refresh button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/roadmap")

      assert html =~ "Refresh"
    end

    test "shows stage columns", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/roadmap")

      assert html =~ "Inbox"
      assert html =~ "Brainstorming"
      assert html =~ "Planned"
      assert html =~ "In Progress"
      assert html =~ "Completed"
    end

    test "shows stat cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/roadmap")

      assert html =~ "Total items"
      assert html =~ "Pipeline"
    end
  end
end
