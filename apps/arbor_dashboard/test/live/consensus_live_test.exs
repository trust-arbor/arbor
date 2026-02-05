defmodule Arbor.Dashboard.Live.ConsensusLiveTest do
  use Arbor.Dashboard.ConnCase, async: true

  describe "ConsensusLive" do
    test "renders consensus dashboard header", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/consensus")

      assert html =~ "Consensus"
      assert html =~ "Council deliberation and decisions"
    end

    test "shows tab buttons", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/consensus")

      assert html =~ "Proposals"
      assert html =~ "Decisions"
    end

    test "shows stat cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/consensus")

      assert html =~ "Total proposals"
      assert html =~ "Active councils"
      assert html =~ "Approved"
      assert html =~ "Rejected"
    end

    test "shows status filter buttons", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/consensus")

      assert html =~ "filter-status"
      assert html =~ "All"
      assert html =~ "Pending"
    end

    test "tab switching works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/consensus")

      html = render_click(view, "select-tab", %{"tab" => "decisions"})
      assert html =~ "decisions-stream"

      html = render_click(view, "select-tab", %{"tab" => "proposals"})
      assert html =~ "proposals-stream"
    end
  end
end
