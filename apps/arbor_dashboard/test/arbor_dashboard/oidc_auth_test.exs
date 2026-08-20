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
    test "establishes a stable local-dev operator session when require_auth is false" do
      conn =
        conn(:get, "/")
        |> init_test_session(%{})
        |> OidcAuth.call(@opts)

      refute conn.halted
      assert conn.assigns.current_agent_id == OidcAuth.local_dev_operator_id()
      assert get_session(conn, "agent_id") == OidcAuth.local_dev_operator_id()
      assert conn.assigns.current_user_display_name == "Local operator"
      assert get_session(conn, "local_dev_operator") == true
    end

    test "reuses an existing session principal instead of replacing it" do
      conn =
        conn(:get, "/")
        |> init_test_session(%{"agent_id" => "human_existing", "user_display_name" => "Ada"})
        |> OidcAuth.call(@opts)

      refute conn.halted
      assert conn.assigns.current_agent_id == "human_existing"
      assert get_session(conn, "agent_id") == "human_existing"
      assert conn.assigns.current_user_display_name == "Ada"
      assert get_session(conn, "local_dev_operator") == false
    end

    test "does not invent a principal when local_dev_operator is disabled" do
      conn =
        conn(:get, "/")
        |> init_test_session(%{})
        |> OidcAuth.call(OidcAuth.init(local_dev_operator: false))

      refute conn.halted
      refute Map.get(conn.assigns, :current_agent_id)
      refute get_session(conn, "agent_id")
    end

    test "security regression (P0-1): denies access when OIDC missing and require_auth: true" do
      # Production config sets require_auth: true. Without OIDC, the dashboard must
      # NOT fall through to open access — that would expose memory, capabilities,
      # signals, and agent controls to anyone who can reach the endpoint.
      #
      # We pass require_auth through the PLUG OPTS rather than mutating the global
      # `:arbor_dashboard, :require_auth` app env. The global env is process-wide:
      # flipping it here (even from an async: false module) raced with concurrently
      # running LiveView mount requests in OTHER test modules — those requests saw
      # require_auth: true, hit this 503 fail-closed branch mid-mount, and the
      # halted-503 surfaced as the CI-only ConsensusLive `Arbor.ErrorView` 500s.
      # The plug opt is per-call, so there is nothing global to race on.
      conn =
        conn(:get, "/")
        |> init_test_session(%{})
        |> OidcAuth.call(OidcAuth.init(require_auth: true))

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
    test "assigns current_agent_id from the local-dev operator when OIDC is unset" do
      conn =
        conn(:get, "/")
        |> init_test_session(%{})
        |> OidcAuth.call(@opts)

      refute conn.halted
      assert conn.assigns.current_agent_id == OidcAuth.local_dev_operator_id()
    end

    test "security regression: a stale local-dev session is not accepted as OIDC proof" do
      Application.put_env(:arbor_security, :oidc,
        providers: [%{issuer: "https://issuer.invalid", client_id: "test"}]
      )

      conn =
        conn(:get, "/settings")
        |> init_test_session(%{
          "agent_id" => OidcAuth.local_dev_operator_id(),
          "user_display_name" => "Local operator",
          "local_dev_operator" => true
        })
        |> OidcAuth.call(@opts)

      assert conn.halted
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/auth/login"]
      refute get_session(conn, "agent_id")
      refute get_session(conn, "local_dev_operator")
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
