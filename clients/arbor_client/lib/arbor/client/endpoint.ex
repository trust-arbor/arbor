defmodule Arbor.Client.Endpoint do
  @moduledoc false

  # One destination policy for login requests and authenticated WebSockets.
  # Plaintext names are deliberately excluded: only literal loopback addresses
  # may carry a login handle or credential without TLS.
  def parse(url, policy \\ :session)

  def parse(url, policy) when is_binary(url) and byte_size(url) <= 2_048 do
    with true <- String.valid?(url) and not Regex.match?(~r/[\x00-\x20\x7f]/, url),
         %URI{
           scheme: scheme,
           host: host,
           port: port,
           userinfo: nil,
           query: nil,
           fragment: nil,
           path: path
         } = uri <- URI.parse(url),
         true <- scheme in ["https", "http", "wss", "ws"],
         true <- is_binary(host) and host != "" and is_integer(port) and port in 1..65_535,
         true <- path in [nil, "", "/", "/api/chat/socket"],
         true <-
           scheme in ["https", "wss"] or host in ["127.0.0.1", "::1"] or
             (policy == :signed and host == "localhost") do
      {:ok, %{uri | scheme: if(scheme in ["https", "wss"], do: "https", else: "http"), path: nil}}
    else
      _ -> {:error, :unsafe_gateway_url}
    end
  rescue
    _ -> {:error, :unsafe_gateway_url}
  end

  def parse(_, _), do: {:error, :unsafe_gateway_url}

  def socket(url, policy \\ :session) do
    with {:ok, uri} <- parse(url, policy),
         do: {:ok, %{uri | scheme: if(uri.scheme == "https", do: "wss", else: "ws")}}
  end
end
