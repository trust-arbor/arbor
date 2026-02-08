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
          {:ok, ^expected_key} ->
            conn

          {:ok, _wrong_key} ->
            reject(conn, "Invalid API key")

          :error ->
            reject(
              conn,
              "Missing API key. Provide via Authorization: Bearer <key> or x-api-key header"
            )
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
          [key] -> {:ok, String.trim(key)}
          _ -> :error
        end
    end
  end

  defp reject(conn, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "Unauthorized", detail: message}))
    |> halt()
  end
end
