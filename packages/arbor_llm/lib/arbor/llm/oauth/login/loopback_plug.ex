defmodule Arbor.LLM.OAuth.Login.LoopbackPlug do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  alias Arbor.LLM.OAuth.Login.LoopbackOwner
  alias Arbor.LLM.OAuth.Login.LoopbackQuery

  @security_headers [
    {"cache-control", "no-store"},
    {"content-security-policy", "default-src 'none'; frame-ancestors 'none'; base-uri 'none'"},
    {"referrer-policy", "no-referrer"},
    {"x-content-type-options", "nosniff"},
    {"connection", "close"}
  ]
  @forwarding_headers ~w(forwarded x-forwarded-for x-forwarded-host x-forwarded-port x-forwarded-proto)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    Process.flag(:sensitive, true)
    flow_id = Keyword.fetch!(opts, :flow_id)
    port = Keyword.fetch!(opts, :port)

    {status, body, terminal?} =
      try do
        dispatch(conn, flow_id, port)
      catch
        _, _ -> {400, "OAuth callback rejected.", false}
      end

    try do
      conn
      |> put_resp_content_type("text/plain", "utf-8")
      |> put_security_headers()
      |> send_resp(status, body)
    catch
      _, _ -> %{conn | state: :sent, halted: true}
    after
      if terminal?, do: LoopbackOwner.response_sent(flow_id)
    end
  end

  defp dispatch(conn, flow_id, port) do
    with :ok <- validate_envelope(conn, port),
         {:ok, callback} <- LoopbackQuery.parse(conn.query_string) do
      case LoopbackOwner.callback(flow_id, callback) do
        :success -> {200, "OpenAI authorization completed. You may close this window.", true}
        :failure -> {400, "OpenAI authorization failed. You may close this window.", true}
        :invalid_state -> {400, "OAuth callback rejected.", false}
      end
    else
      _ -> {400, "OAuth callback rejected.", false}
    end
  end

  defp validate_envelope(conn, port) do
    expected_host = "localhost:#{port}"

    cond do
      conn.scheme != :http -> {:error, :invalid_envelope}
      conn.method != "GET" -> {:error, :invalid_envelope}
      conn.request_path != "/auth/callback" -> {:error, :invalid_envelope}
      conn.path_info != ["auth", "callback"] -> {:error, :invalid_envelope}
      conn.host != "localhost" or conn.port != port -> {:error, :invalid_envelope}
      get_req_header(conn, "host") != [expected_host] -> {:error, :invalid_envelope}
      not http1?(conn.adapter) -> {:error, :invalid_envelope}
      not loopback_peer?(get_peer_data(conn)) -> {:error, :invalid_envelope}
      has_forwarding_headers?(conn) -> {:error, :invalid_envelope}
      get_req_header(conn, "content-length") != [] -> {:error, :invalid_envelope}
      get_req_header(conn, "transfer-encoding") != [] -> {:error, :invalid_envelope}
      has_body?(conn.adapter) -> {:error, :invalid_envelope}
      true -> :ok
    end
  end

  defp http1?({Plug.Cowboy.Conn, %{version: version}}),
    do: version in [:"HTTP/1.0", :"HTTP/1.1"]

  defp http1?(_adapter), do: false

  defp has_body?({Plug.Cowboy.Conn, %{has_body: value}}), do: value
  defp has_body?(_adapter), do: true

  defp loopback_peer?(%{address: {127, _b, _c, _d}}), do: true
  defp loopback_peer?(%{address: {0, 0, 0, 0, 0, 0, 0, 1}}), do: true
  defp loopback_peer?(_peer), do: false

  defp has_forwarding_headers?(conn) do
    Enum.any?(@forwarding_headers, &(get_req_header(conn, &1) != []))
  end

  defp put_security_headers(conn) do
    Enum.reduce(@security_headers, conn, fn {name, value}, acc ->
      put_resp_header(acc, name, value)
    end)
  end
end
