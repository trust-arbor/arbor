defmodule Arbor.Dashboard.Live.SettingsLiveTest do
  use Arbor.Dashboard.ConnCase, async: true

  describe "SettingsLive" do
    test "renders page header", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")

      assert html =~ "Settings"
      assert html =~ "External Agents"
    end

    test "shows External Agents section description", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")

      assert html =~ "Register external tools"
      assert html =~ "Ed25519 keypair"
      assert html =~ "shown"
    end

    test "unauthenticated user sees sign-in prompt instead of register button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")

      assert html =~ "Sign in to register external agents"
      refute html =~ "Register New"
    end

    test "settings link is present in nav", %{conn: conn} do
      # The Settings page itself should render its own nav
      # (rendered via the layout's nav_items assign).
      {:ok, _view, html} = live(conn, "/settings")

      assert html =~ "/settings"
      assert html =~ "Settings"
    end
  end
end
