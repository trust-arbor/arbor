defmodule Arbor.Dashboard.EndpointExposureSecurityRegressionTest do
  use Arbor.Dashboard.ConnCase, async: false

  @moduletag :fast

  # 2026-10-11 cross-library review F-001 / F-012. The dashboard listened on
  # every interface with no authentication in the dev profile (each request
  # became `human_dashboard`), and the documented DASHBOARD_USER/PASS basic
  # auth plug was never mounted. Both the loopback default and the mounted
  # plug are pinned here.
  setup do
    prev_user = Application.get_env(:arbor_dashboard, :auth_user)
    prev_pass = Application.get_env(:arbor_dashboard, :auth_pass)

    on_exit(fn ->
      restore(:auth_user, prev_user)
      restore(:auth_pass, prev_pass)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:arbor_dashboard, key)
  defp restore(key, value), do: Application.put_env(:arbor_dashboard, key, value)

  test "security regression (F-001): the endpoint binds to loopback unless an operator overrides it" do
    http = Application.get_env(:arbor_dashboard, Arbor.Dashboard.Endpoint)[:http]

    assert Keyword.get(http, :ip) == {127, 0, 0, 1},
           "runtime.exs must pin the dashboard to loopback by default; got #{inspect(http)}"
  end

  test "security regression (F-012): configured basic-auth credentials gate the endpoint", %{
    conn: conn
  } do
    Application.put_env(:arbor_dashboard, :auth_user, "arbor")
    Application.put_env(:arbor_dashboard, :auth_pass, "s3cret")

    conn = get(conn, "/")

    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") != []
  end
end
