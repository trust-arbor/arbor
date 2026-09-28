defmodule Arbor.AI.AcpPool.ToolServer.BearerAuth do
  @moduledoc """
  Per-session bearer-token gate in front of `ExMCP.HttpPlug` for the ACP
  `ToolServer` (Imp review D6, 2026-09-27).

  The ToolServer executes Jido actions through `authorize_and_execute/4` as its
  owning agent, so whoever can reach its port acts with that agent's
  capabilities. Loopback binding keeps it off the network, and ex_mcp's Origin
  check already refuses browser requests, but any local, non-browser process
  that found the port (a port scan is enough) was served without credentials.

  `ToolServer.start/2` mints a random token per server and puts it in the ACP
  `mcpServers` descriptor's `headers` (the only party given it is the spawned
  coding agent). Every request must carry `authorization: Bearer <token>`;
  anything else gets `401` before ex_mcp parses the body. Compared in constant
  time. ex_mcp 1.3.0's own auth hook is OAuth-introspection-only, hence a
  wrapper plug rather than an HttpPlug option.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts) do
    token = Keyword.fetch!(opts, :token)

    unless is_binary(token) and byte_size(token) >= 32 do
      raise ArgumentError, "ToolServer bearer token must be a binary of at least 32 bytes"
    end

    %{token: token, mcp: ExMCP.HttpPlug.init(Keyword.fetch!(opts, :mcp))}
  end

  @impl Plug
  def call(conn, %{token: token, mcp: mcp_opts}) do
    if authorized?(conn, token) do
      ExMCP.HttpPlug.call(conn, mcp_opts)
    else
      conn
      |> put_resp_header("www-authenticate", ~s(Bearer realm="arbor-tools"))
      |> put_resp_content_type("application/json")
      |> send_resp(401, ~s({"error":"unauthorized"}))
      |> halt()
    end
  end

  # Exactly one Authorization header carrying the exact bearer. A missing,
  # duplicated, or differently-schemed header is a denial.
  defp authorized?(conn, token) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> presented] -> Plug.Crypto.secure_compare(presented, token)
      _ -> false
    end
  end
end
