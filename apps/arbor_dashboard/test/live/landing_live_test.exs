defmodule Arbor.Dashboard.Live.LandingLiveTest do
  use Arbor.Dashboard.ConnCase, async: true

  describe "LandingLive" do
    test "renders landing page header", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Arbor Dashboard"
      assert html =~ "Agent orchestration control plane"
    end

    test "shows navigation cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Signals"
      assert html =~ "Evaluation"
      assert html =~ "Open Signals Dashboard"
      assert html =~ "Open Eval Dashboard"
    end

    test "shows coming soon cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Trust &amp; Security"
      assert html =~ "Consensus"
      assert html =~ "Coming Soon"
    end

    test "shows system info section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "System Info"
      assert html =~ "OTP Release"
      assert html =~ "Elixir"
    end

    test "shows stat cards with signal data", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Signals"
      assert html =~ "Subscriptions"
      assert html =~ "System health"
      assert html =~ "OTP apps"
    end
  end
end
