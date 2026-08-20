defmodule Arbor.Gateway.Auth do
  @moduledoc """
  API key authentication plug for the Gateway HTTP API.

  Checks for a valid API key in the `Authorization` header (as `Bearer <key>`)
  or the `x-api-key` header. The expected key is configured via the
  `ARBOR_GATEWAY_API_KEY` environment variable.

  If no API key is configured, all requests are rejected with a clear error
  message instructing the operator to set the environment variable.
  """

  import Plug.Conn
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case get_configured_key() do
      nil ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          503,
          Jason.encode!(%{
            error: "Gateway API key not configured",
            detail: "Set ARBOR_GATEWAY_API_KEY environment variable"
          })
        )
        |> halt()

      expected_key ->
        case extract_key(conn) do
          {:ok, presented_key} ->
            # M4: pattern-match on ^expected_key is NOT constant-time and
            # leaks the key character-by-character through timing analysis.
            # Plug.Crypto.secure_compare/2 is constant-time (XOR-based).
            if Plug.Crypto.secure_compare(presented_key, expected_key) do
              conn
            else
              reject(conn, "Invalid API key")
            end

          :error ->
            reject(conn, no_key_message(conn))
        end
    end
  end

  defp get_configured_key do
    Application.get_env(:arbor_gateway, :api_key) ||
      System.get_env("ARBOR_GATEWAY_API_KEY")
  end

  defp extract_key(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> key] ->
        {:ok, String.trim(key)}

      _ ->
        case get_req_header(conn, "x-api-key") do
          [key] ->
            {:ok, String.trim(key)}

          _ ->
            # M4: the previous fallback accepted `?token=<key>` query parameters
            # so the secret would land in:
            #   * Plug.Logger access logs
            #   * any reverse-proxy access log
            #   * the browser history of anyone who pasted a URL
            #   * the Referer header on outbound requests from rendered pages
            # The MCP-clients-can't-send-headers concern is now handled at the
            # MCP client level (the spec requires header support); the
            # query-param escape hatch is removed.
            :error
        end
    end
  end

  # A request that presented a signature and failed verification is NOT a
  # request that forgot its credentials. Saying "Missing API key" there is
  # actively misleading — it hides a real, actionable server-side reason
  # behind advice to add a header the caller does not need.
  defp no_key_message(conn) do
    case conn.assigns[:signed_request_auth_error] do
      nil ->
        "Missing API key. Provide via Authorization: Bearer <key> or x-api-key header"

      reason ->
        "Signed request verification failed: #{describe_signature_failure(reason)}"
    end
  end

  # Only reasons that are properties of THIS NODE's state are spelled out.
  # Per-principal outcomes (unknown agent, bad signature, replayed nonce) stay
  # generic so this cannot be used to enumerate or probe identities.
  defp describe_signature_failure(:cluster_replay_protection_unavailable) do
    "cluster_replay_protection_unavailable — this node is connected to a peer " <>
      "running :arbor_security, so a captured request could be replayed there. " <>
      "Disconnect the peer (mix arbor.cluster disconnect <node>) or run single-node."
  end

  defp describe_signature_failure(_reason), do: "signature rejected"

  defp reject(conn, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "Unauthorized", detail: message}))
    |> halt()
  end
end
