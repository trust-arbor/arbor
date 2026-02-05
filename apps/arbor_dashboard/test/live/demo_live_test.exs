defmodule Arbor.Dashboard.Live.DemoLiveTest do
  use Arbor.Dashboard.ConnCase, async: true

  describe "DemoLive" do
    test "renders demo page header", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/demo")

      assert html =~ "Self-Healing Demo"
      assert html =~ "BEAM fault injection"
    end

    test "shows pipeline stages", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/demo")

      assert html =~ "Detect"
      assert html =~ "Diagnose"
      assert html =~ "Propose"
      assert html =~ "Review"
      assert html =~ "Fix"
      assert html =~ "Verify"
    end

    test "shows fault injection controls", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/demo")

      assert html =~ "Fault Injection"
      assert html =~ "Inject"
    end

    test "shows empty state when no faults active", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/demo")

      assert html =~ "No active faults"
    end

    test "shows monitor status section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/demo")

      assert html =~ "Monitor Status"
      assert html =~ "Processes"
      assert html =~ "Memory"
      assert html =~ "Anomalies"
    end

    test "shows activity feed section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/demo")

      assert html =~ "Activity Feed"
      assert html =~ "No activity yet"
    end
  end
end
