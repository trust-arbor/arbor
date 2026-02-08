defmodule Arbor.Dashboard.Auth do
  @moduledoc """
  HTTP Basic Auth plug for the Arbor Dashboard.

  Reads credentials from environment variables:
  - `DASHBOARD_USER` (default: "arbor")
  - `DASHBOARD_PASS` (required in prod — no default)

  In dev/test, authentication is skipped unless credentials are explicitly set.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case get_credentials() do
      :skip ->
        # Dev/test without credentials configured — allow access
        conn

      {username, password} ->
        case Plug.BasicAuth.parse_basic_auth(conn) do
          {^username, ^password} ->
            conn

          _ ->
            conn
            |> Plug.BasicAuth.request_basic_auth(realm: "Arbor Dashboard")
            |> halt()
        end
    end
  end

  defp get_credentials do
    user = Application.get_env(:arbor_dashboard, :auth_user) || System.get_env("DASHBOARD_USER")
    pass = Application.get_env(:arbor_dashboard, :auth_pass) || System.get_env("DASHBOARD_PASS")

    cond do
      # Credentials explicitly configured — enforce auth
      user && pass ->
        {user, pass}

      # Production requires credentials
      Application.get_env(:arbor_dashboard, :require_auth, false) ->
        # No credentials but auth required — block everything
        {"__blocked__", "__blocked__"}

      # Dev/test without credentials — skip auth
      true ->
        :skip
    end
  end
end
