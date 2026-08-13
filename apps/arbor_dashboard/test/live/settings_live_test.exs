defmodule Arbor.Dashboard.Live.SettingsLiveTest do
  # async: false — tests that flip `:dev_local_operator` must not race with
  # other LiveView mounts that expect the ConnCase pin (false).
  use Arbor.Dashboard.ConnCase, async: false

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
      # ConnCase pins `:dev_local_operator` false so this covers the gated path.
      {:ok, _view, html} = live(conn, "/settings")

      assert html =~ "Sign in to register external agents"
      refute html =~ "Register New"
    end

    test "dev_local_operator auto-login shows Register New without OIDC", %{conn: conn} do
      Application.put_env(:arbor_dashboard, :dev_local_operator, true)
      on_exit(fn -> Application.put_env(:arbor_dashboard, :dev_local_operator, false) end)

      {:ok, _view, html} = live(conn, "/settings")

      assert html =~ "Register New"
      refute html =~ "Sign in to register external agents"
      assert html =~ "Local Dev Operator"
    end

    test "submit_registration without authentication fails closed", %{conn: conn} do
      # Explicitly gated: no OIDC, no local operator → empty session principal.
      Application.put_env(:arbor_dashboard, :dev_local_operator, false)

      {:ok, view, html} = live(conn, "/settings")
      assert html =~ "Sign in to register external agents"

      # Event can still be pushed even when the UI hides the form.
      result =
        render_click(view, "external_agents:submit_registration", %{
          "display_name" => "Should Not Create",
          "agent_type" => "claude_code"
        })

      assert result =~ "Sign in required"
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
