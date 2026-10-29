defmodule Arbor.Gateway.MCP.ToolPinStoreCore do
  @moduledoc """
  Pure encode/decode of durable MCP tool-fingerprint pins.

  Pins are keyed by the server's approved config identity
  (`Arbor.Security.mcp_server_approval_uri/2`) and the tool name. The
  payload is JSON-clean so the gateway file store can publish it.
  """

  @type pin_map :: %{optional(String.t()) => String.t()}

  @hash_re ~r/^[0-9a-f]{64}$/

  @doc """
  Config identity for a named MCP server.

  Uses the existing approval digest so pins follow the same identity as
  `set_mcp_config` grants. A config that cannot produce an approval URI
  falls back to a name-plus-config digest under the same prefix.
  """
  @spec identity(String.t(), map()) :: String.t()
  def identity(server_name, config) when is_binary(server_name) and is_map(config) do
    case Arbor.Security.mcp_server_approval_uri(server_name, config) do
      {:ok, uri} ->
        uri

      {:error, _} ->
        digest = sha256(:erlang.term_to_binary({server_name, fallback_projection(config)}))
        "arbor://mcp_server/connect/unapproved/#{digest}"
    end
  end

  @spec encode(String.t(), pin_map()) :: {:ok, String.t()} | {:error, :unreadable}
  def encode(identity, pins) when is_binary(identity) and is_map(pins) do
    case pin_map(pins) do
      {:ok, pins} ->
        Jason.encode(%{"v" => 1, "identity" => identity, "pins" => pins})

      {:error, _} = error ->
        error
    end
  end

  @spec decode(String.t(), String.t()) :: {:ok, pin_map()} | {:error, :unreadable}
  def decode(contents, identity) when is_binary(contents) and is_binary(identity) do
    case Jason.decode(contents) do
      {:ok, %{"v" => 1, "identity" => ^identity, "pins" => pins}} ->
        pin_map(pins)

      _other ->
        {:error, :unreadable}
    end
  end

  @spec file_name(String.t()) :: String.t()
  def file_name(identity) when is_binary(identity), do: sha256(identity) <> ".json"

  defp pin_map(pins) when is_map(pins) do
    if Enum.all?(pins, &valid_pin?/1) do
      {:ok, Map.new(pins, fn {name, hash} -> {name, hash} end)}
    else
      {:error, :unreadable}
    end
  end

  defp pin_map(_pins), do: {:error, :unreadable}

  defp valid_pin?({name, hash})
       when is_binary(name) and name != "" and is_binary(hash),
       do: Regex.match?(@hash_re, hash)

  defp valid_pin?(_pair), do: false

  defp fallback_projection(config) do
    Enum.map([:transport, :command, :env, :url, :server], fn field ->
      {Atom.to_string(field), Map.get(config, field) || Map.get(config, Atom.to_string(field))}
    end)
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
