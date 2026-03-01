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

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
