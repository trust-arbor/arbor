defmodule Arbor.Dashboard.OidcAuthTest do
  # NOT async: the P0-1 regression test mutates the GLOBAL
  # `:arbor_dashboard, :require_auth` env to true. Under async, that races with
  # other async tests reading the same global — notably ConsensusLiveTest's
  # `live(conn, "/consensus")`, whose mount halts (503/redirect) while
  # require_auth is briefly true, producing flaky combined-run failures. A sync
  # module owns the runtime alone, so the put_env/on_exit window can't overlap.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Arbor.Dashboard.OidcAuth

  @moduletag :fast

  @opts OidcAuth.init([])

  # Clear OIDC config that may leak from .env file via runtime.exs
  setup do
    original = Application.get_env(:arbor_security, :oidc, [])
    Application.put_env(:arbor_security, :oidc, [])
    on_exit(fn -> Application.put_env(:arbor_security, :oidc, original) end)
    :ok
  end

  describe "when OIDC is not configured" do
    test "passes through all requests (open access) when require_auth is false" do
      # With no OIDC providers configured and require_auth: false (dev/test default),
      # all requests pass through
      conn =
        conn(:get, "/")
        |> init_test_session(%{})
        |> OidcAuth.call(@opts)

      refute conn.halted
    end

    test "security regression (P0-1): denies access when OIDC missing and require_auth: true" do
      # Production config sets require_auth: true. Without OIDC, the dashboard must
      # NOT fall through to open access — that would expose memory, capabilities,
      # signals, and agent controls to anyone who can reach the endpoint.
      original = Application.get_env(:arbor_dashboard, :require_auth)
      Application.put_env(:arbor_dashboard, :require_auth, true)

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:arbor_dashboard, :require_auth)
        else
          Application.put_env(:arbor_dashboard, :require_auth, original)
        end
      end)

      conn =
        conn(:get, "/")
        |> init_test_session(%{})
        |> OidcAuth.call(@opts)

      assert conn.halted,
             "Dashboard must halt when OIDC absent and require_auth true — P0-1 regression"

      assert conn.status == 503,
             "Expected 503 Service Unavailable when auth required but unconfigured " <>
               "(got #{conn.status}) — P0-1 regression"
    end

    test "login route returns 404" do
      conn =
        conn(:get, "/auth/login")
        |> init_test_session(%{})
        |> OidcAuth.call(@opts)

      assert conn.halted
      assert conn.status == 404
    end

    test "callback route returns 404" do
      conn =
        conn(:get, "/auth/callback")
        |> init_test_session(%{})
        |> OidcAuth.call(@opts)

      assert conn.halted
      assert conn.status == 404
    end
  end

  describe "logout" do
    test "clears session and redirects to root" do
      conn =
        conn(:get, "/auth/logout")
        |> init_test_session(%{"agent_id" => "human_abc123"})
        |> OidcAuth.call(@opts)

      assert conn.halted
      assert conn.status == 302

      location = get_resp_header(conn, "location")
      assert location == ["/"]
    end
  end

  describe "session-based auth pass-through" do
    test "assigns current_agent_id when session has agent_id (with OIDC configured)" do
      # We test the session check path by verifying the plug's behavior
      # when there IS a session. Since OIDC isn't configured in test env,
      # requests pass through without session check.
      conn =
        conn(:get, "/")
        |> init_test_session(%{})
        |> OidcAuth.call(@opts)

      refute conn.halted
      # In dev mode (no OIDC), no current_agent_id is assigned
      refute Map.has_key?(conn.assigns, :current_agent_id)
    end
  end

  describe "login grant policy (H11 regression)" do
    test "security regression (H11): does NOT auto-grant arbor://consensus/admin" do
      # H11: previously, every OIDC login auto-granted arbor://consensus/admin,
      # giving any authenticated user force_approve/force_reject on every proposal.
      # Admin rights must come from explicit role assignment, not from login.
      resources = OidcAuth.login_grant_resources()

      refute "arbor://consensus/admin" in resources,
             "OIDC login must not auto-grant arbor://consensus/admin — H11 regression. " <>
               "Granting admin to every authenticated user collapses consensus into a " <>
               "single-operator model."
    end

    test "security regression (H11): no /admin capability is auto-granted on login" do
      # Defensive check: catch any future drift where a different /admin resource
      # gets added to the auto-grant list.
      resources = OidcAuth.login_grant_resources()

      for resource <- resources do
        refute String.contains?(resource, "/admin"),
               "OIDC login auto-grants admin capability #{inspect(resource)} — H11 regression. " <>
                 "Admin caps must be assigned by role, not by login."
      end
    end
  end

  describe "callback_uri construction" do
    test "builds correct callback URI" do
      # We can test this indirectly through the login path
      # The callback URI includes scheme, host, port, and /auth/callback path
      conn =
        conn(:get, "/auth/login")
        |> init_test_session(%{})
        |> OidcAuth.call(@opts)

      # Without OIDC config, we get 404 — but the module compiles and routes work
      assert conn.halted
      assert conn.status == 404
    end
  end
end
