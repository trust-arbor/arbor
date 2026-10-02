defmodule Arbor.Web.VoiceConnectionSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @marker "x-arbor-voice-direct"

  defmodule Endpoint do
    use Arbor.Web.Endpoint, otp_app: :arbor_web
  end

  setup do
    previous = Application.fetch_env(:arbor_web, Endpoint)

    Application.put_env(:arbor_web, Endpoint,
      server: false,
      secret_key_base: String.duplicate("test-only-secret", 8),
      check_origin: ["//localhost"]
    )

    start_supervised!(Endpoint)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_web, Endpoint, value)
        :error -> Application.delete_env(:arbor_web, Endpoint)
      end
    end)

    :ok
  end

  test "security regression: raw proxy provenance cannot survive transport filtering as direct" do
    for proxy <- ["forwarded", "via", "x-forwarded-for", "x-real-ip"] do
      headers = connect_headers([{proxy, "remote-client"}, {@marker, "true"}])
      assert Enum.filter(headers, fn {name, _} -> name == @marker end) == [{@marker, "false"}]
    end
  end

  test "security regression: duplicate forged markers are replaced before a normal live upgrade" do
    headers =
      connect_headers([
        {@marker, "true"},
        {"forwarded", "for=203.0.113.8;host=localhost"},
        {@marker, "true"}
      ])

    assert Enum.filter(headers, fn {name, _} -> name == @marker end) == [{@marker, "false"}]
  end

  test "direct live transport gets server-derived evidence even if the client supplies a marker" do
    for request <- [[], [{@marker, "false"}], [{@marker, "true"}, {@marker, "false"}]] do
      headers = connect_headers(request)
      assert Enum.filter(headers, fn {name, _} -> name == @marker end) == [{@marker, "true"}]
    end
  end

  defp connect_headers(headers) do
    conn = Plug.Test.conn(:get, "http://localhost/live/websocket?vsn=2.0.0")

    conn = %{
      conn
      | req_headers:
          headers ++
            [
              {"host", "localhost"},
              {"connection", "upgrade"},
              {"upgrade", "websocket"},
              {"sec-websocket-version", "13"},
              {"sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ=="}
            ]
    }

    assert %{state: :upgraded} = Endpoint.call(conn, [])

    assert_received {_ref, :upgrade,
                     {:websocket, {Phoenix.LiveView.Socket, {_state, socket}, _opts}}}

    socket.private.connect_info.x_headers
  end
end
