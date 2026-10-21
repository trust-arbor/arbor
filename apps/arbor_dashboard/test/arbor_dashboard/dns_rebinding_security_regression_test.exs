defmodule Arbor.Dashboard.DnsRebindingSecurityRegressionTest do
  use Arbor.Dashboard.ConnCase, async: false

  import Plug.Conn

  alias Arbor.Dashboard.OidcAuth

  @moduletag :fast

  @evil_host "evil.example"
  @probe_path "/dns-rebind-probe"

  # 2026-10-21 Exposure Check group L. Binding the dashboard to loopback is
  # not enough: a page served on a public name can rebind that name to
  # 127.0.0.1:4001. The browser then sends Host: evil.example (and Origin:
  # http://evil.example) to the no-auth operator UI. This file must fail on
  # main before the Host/Origin guards land.

  describe "no-auth HTTP Host allowlist" do
    test "security regression: Host evil.example is 403 and does not mint human_dashboard" do
      conn = request(@evil_host, @probe_path)

      assert conn.status == 403,
             "DNS-rebinding Host #{@evil_host} must be rejected before Tidewave " <>
               "or OidcAuth run (got #{inspect(conn.status)})"

      assert conn.halted
      refute operator_session?(conn)
    end

    test "security regression: loopback Host still works and may mint the local operator" do
      for host <- ["localhost", "127.0.0.1", "[::1]"] do
        conn = request(host, @probe_path)

        refute conn.status == 403,
               "loopback Host #{host} must remain reachable in no-auth mode " <>
                 "(got #{inspect(conn.status)})"

        assert operator_session?(conn),
               "loopback Host #{host} must still receive the local operator session"
      end
    end

    test "security regression: ARBOR_DEV_ALLOW_ANY_HOST opts out of the Host gate" do
      previous = Application.get_env(:arbor_web, :dev_allow_any_host)
      Application.put_env(:arbor_web, :dev_allow_any_host, true)

      on_exit(fn -> restore_env(:dev_allow_any_host, previous) end)

      conn = request(@evil_host, @probe_path)
      refute conn.status == 403
      assert operator_session?(conn)
    end

    test "security regression: ARBOR_DEV_ALLOWED_HOSTS admits a named LAN host" do
      previous = Application.get_env(:arbor_web, :dev_allowed_hosts)
      Application.put_env(:arbor_web, :dev_allowed_hosts, ["devbox.local"])

      on_exit(fn -> restore_env(:dev_allowed_hosts, previous) end)

      conn = request("devbox.local", @probe_path)
      refute conn.status == 403
      assert operator_session?(conn)
    end
  end

  describe "no-auth OidcAuth Host gate" do
    test "security regression: OidcAuth does not mint human_dashboard for a rebinding Host" do
      conn =
        Plug.Test.conn(:get, "http://#{@evil_host}#{@probe_path}")
        |> Phoenix.ConnTest.init_test_session(%{})
        |> OidcAuth.call(OidcAuth.init([]))

      refute conn.assigns[:current_agent_id] == OidcAuth.local_dev_operator_id(),
             "OidcAuth must not auto-create human_dashboard when Host is #{@evil_host}"

      refute get_session(conn, "agent_id") == OidcAuth.local_dev_operator_id()
      refute get_session(conn, "local_dev_operator") == true
    end

    test "security regression: OidcAuth still mints the local operator on loopback Host" do
      conn =
        Plug.Test.conn(:get, "http://localhost#{@probe_path}")
        |> Phoenix.ConnTest.init_test_session(%{})
        |> OidcAuth.call(OidcAuth.init([]))

      refute conn.halted
      assert conn.assigns.current_agent_id == OidcAuth.local_dev_operator_id()
      assert get_session(conn, "agent_id") == OidcAuth.local_dev_operator_id()
    end
  end

  describe "no-auth LiveView Origin allowlist" do
    test "security regression: check_origin is a loopback allowlist, not false" do
      origins = Arbor.Dashboard.Endpoint.config(:check_origin)

      refute origins == false,
             "check_origin: false lets a rebound page connect a LiveView socket"

      assert is_list(origins),
             "no-auth check_origin must be an explicit loopback origin list, got #{inspect(origins)}"

      for host <- ["localhost", "127.0.0.1", "[::1]"] do
        assert Enum.any?(origins, &origin_names_host?(&1, host)),
               "check_origin must allow #{host}, got #{inspect(origins)}"
      end
    end

    test "security regression: LiveView socket with a non-localhost Origin is refused" do
      conn = live_upgrade(origin: "http://#{@evil_host}", host: "localhost")

      refute conn.state == :upgraded,
             "a rebound Origin must not upgrade the LiveView socket"

      assert conn.status == 403
      assert conn.halted
    end

    test "security regression: LiveView socket with a loopback Origin is admitted" do
      port = dashboard_port()
      conn = live_upgrade(origin: "http://localhost:#{port}", host: "localhost")

      assert conn.state == :upgraded,
             "loopback Origin http://localhost:#{port} must still be able to connect"
    end
  end

  defp request(host, path) do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, host)
    |> get(path)
  end

  defp operator_session?(conn) do
    operator = OidcAuth.local_dev_operator_id()

    conn.assigns[:current_agent_id] == operator or
      (has_session?(conn) and get_session(conn, "agent_id") == operator)
  end

  defp has_session?(%{private: %{plug_session: _}}), do: true
  defp has_session?(_), do: false

  defp live_upgrade(opts) do
    host = Keyword.fetch!(opts, :host)
    origin = Keyword.fetch!(opts, :origin)
    conn = Plug.Test.conn(:get, "http://#{host}/live/websocket?vsn=2.0.0")

    conn = %{
      conn
      | host: host,
        req_headers: [
          {"host", host},
          {"origin", origin},
          {"connection", "upgrade"},
          {"upgrade", "websocket"},
          {"sec-websocket-version", "13"},
          {"sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ=="}
        ]
    }

    Arbor.Dashboard.Endpoint.call(conn, [])
  end

  defp dashboard_port do
    http = Application.get_env(:arbor_dashboard, Arbor.Dashboard.Endpoint)[:http] || []
    Keyword.get(http, :port, 4002)
  end

  defp origin_names_host?(origin, host) when is_binary(origin) do
    String.contains?(origin, host)
  end

  defp origin_names_host?(_, _), do: false

  defp restore_env(key, nil), do: Application.delete_env(:arbor_web, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_web, key, value)
end
