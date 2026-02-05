defmodule Arbor.Dashboard.Live.AgentsLiveTest do
  use Arbor.Dashboard.ConnCase, async: true

  describe "AgentsLive" do
    test "renders agents dashboard header", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents")

      assert html =~ "Agents"
      assert html =~ "Running agent instances and profiles"
    end

    test "shows stat cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents")

      assert html =~ "Running"
      assert html =~ "Profiles"
    end

    test "shows agents stream container", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents")

      assert html =~ "agents-stream"
    end
  end
end
