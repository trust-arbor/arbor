defmodule Arbor.Gateway.HttpServerOptions do
  @moduledoc """
  Pure builder for the Cowboy options the Gateway HTTP server starts with.

  Cowboy closes an HTTP/1.1 connection that has received no bytes for
  `idle_timeout` (default 60 s) — including one whose request is still
  being served. A signed MCP call that legitimately runs longer than that
  (a council consultation, a long `arbor_run`) then loses its connection;
  `:httpc` in `mix arbor.signer` transparently re-sends the identical
  signed body on a fresh connection, and the gateway correctly rejects it
  as `:replayed_nonce` (HTTP 401) — the original result is never seen.
  The idle timeout therefore has to cover the longest handler call.
  """

  @idle_margin_ms 15_000

  @doc """
  Returns `[port:, ip:, protocol_options: [idle_timeout: ms]]`.

  `idle_timeout` is the larger of the configured `http_idle_timeout_ms` (if
  any) and the MCP handler call timeout plus a #{@idle_margin_ms} ms margin,
  so a request can never outlive its connection.
  """
  @spec build(keyword()) :: keyword()
  def build(opts) do
    port = Keyword.fetch!(opts, :port)
    ip = Keyword.fetch!(opts, :ip)
    handler_timeout = Keyword.fetch!(opts, :handler_call_timeout_ms)
    configured = Keyword.get(opts, :http_idle_timeout_ms)

    [
      port: port,
      ip: ip,
      protocol_options: [idle_timeout: idle_timeout(handler_timeout, configured)]
    ]
  end

  @doc false
  def idle_timeout(handler_timeout_ms, configured_ms)
      when is_integer(handler_timeout_ms) and handler_timeout_ms > 0 do
    floor = handler_timeout_ms + @idle_margin_ms

    case configured_ms do
      ms when is_integer(ms) and ms > floor -> ms
      _ -> floor
    end
  end
end
