defmodule Arbor.Dashboard.ConnCase do
  @moduledoc """
  Test case template for LiveView tests in the Arbor Dashboard.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint Arbor.Dashboard.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
    end
  end

  setup _tags do
    # Clear OIDC config so OidcAuth plug allows open access in tests.
    # Without this, .env file OIDC settings leak into test env via runtime.exs,
    # causing all LiveView tests to get redirected to /auth/login.
    Application.put_env(:arbor_security, :oidc, [])

    # Pin require_auth OFF for every LiveView mount. The OidcAuth plug returns a
    # fail-closed 503 when require_auth is true and no OIDC provider is configured
    # — which Phoenix.LiveViewTest can't handle (halted 503 → FunctionClauseError →
    # 500 → missing Arbor.ErrorView). require_auth can become true via the prod
    # runtime.exs path or the OidcAuthTest P0-1 regression test; clearing :oidc
    # above is not enough on its own. Resetting it here makes the test env
    # deterministically open-access regardless of how it got flipped.
    Application.put_env(:arbor_dashboard, :require_auth, false)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
