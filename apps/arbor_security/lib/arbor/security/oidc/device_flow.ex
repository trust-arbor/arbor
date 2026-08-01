defmodule Arbor.Security.OIDC.DeviceFlow do
  @moduledoc """
  RFC 8628 Device Authorization Grant for CLI authentication.

  This module preserves the public shape used by `Arbor.Security.authenticate_oidc/1`
  and delegates transport/parsing to the provider-neutral
  `Arbor.Common.OAuth.DeviceCode` primitive.

  Endpoint trust remains in Security via `Arbor.Security.OIDC.Discovery`.
  """

  alias Arbor.Common.OAuth.DeviceCode
  alias Arbor.Security.OIDC.Discovery

  @default_scopes ["openid", "email", "profile"]
  @default_timeout_ms 10_000
  @default_poll_timeout_ms 300_000
  @default_max_response_bytes 65_536
  @default_discovery_timeout_ms 10_000
  @default_discovery_max_response_bytes 262_144

  @default_poll_interval 5

  @token_response_schema %{
    "id_token" => :required_string,
    "access_token" => :optional_string,
    "token_type" => :optional_string,
    "refresh_token" => :optional_string,
    "scope" => :optional_string,
    "expires_in" => :optional_integer
  }

  @doc """
  Start the device authorization flow.

  Fetches the provider's OIDC discovery document and resolves the trusted
  `device_authorization_endpoint`, then requests a device code.
  """
  @spec start(map()) :: {:ok, map()} | {:error, term()}
  def start(%{issuer: _issuer, client_id: client_id} = config) do
    with :ok <- validate_scope_options(config),
         {:ok, endpoints} <- discover(config, :device),
         {:ok, endpoint} <-
           require_endpoint(
             Map.get(endpoints, :device_authorization_endpoint),
             :no_device_authorization_endpoint
           ),
         {:ok, response} <-
           DeviceCode.start(
             device_authorization_endpoint: endpoint,
             client_id: client_id,
             client_secret: Map.get(config, :client_secret),
             scopes: scopes_for(config),
             scope: Map.get(config, :scope),
             max_response_bytes:
               config_get(config, :max_response_bytes, @default_max_response_bytes),
             timeout_ms: config_get(config, :timeout_ms, @default_timeout_ms),
             allow_http: allow_http?(config),
             http_client: Map.get(config, :http_client)
           ) do
      {:ok, response}
    else
      {:error, reason} -> normalize_error(reason)
    end
  end

  @doc """
  Poll the token endpoint until the user authorizes or the flow terminates.
  """
  @spec poll(map(), map()) :: {:ok, map()} | {:error, term()}
  def poll(%{issuer: _issuer, client_id: client_id} = config, device_response) do
    device_code = device_response["device_code"] || device_response[:device_code]
    interval = device_response["interval"] || device_response[:interval] || @default_poll_interval
    expires_in = device_response["expires_in"] || device_response[:expires_in]

    with {:ok, endpoints} <- discover(config, :token),
         {:ok, endpoint} <-
           require_endpoint(Map.get(endpoints, :token_endpoint), :no_token_endpoint),
         {:ok, token_schema} <-
           DeviceCode.validate_token_response_schema(
             Map.get(config, :response_schema, @token_response_schema)
           ),
         {:ok, response} <-
           DeviceCode.poll(
             token_endpoint: endpoint,
             client_id: client_id,
             client_secret: Map.get(config, :client_secret),
             device_code: device_code,
             response_schema: token_schema,
             interval: interval,
             expires_in: expires_in,
             poll_timeout_ms: config_get(config, :poll_timeout_ms, @default_poll_timeout_ms),
             max_response_bytes:
               config_get(config, :max_response_bytes, @default_max_response_bytes),
             timeout_ms: config_get(config, :timeout_ms, @default_timeout_ms),
             allow_http: allow_http?(config),
             http_client: Map.get(config, :http_client)
           ) do
      {:ok, response}
    else
      {:error, reason} -> normalize_error(reason)
    end
  end

  @doc """
  Refresh tokens with the trusted token endpoint.
  """
  @spec refresh(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def refresh(%{issuer: _issuer, client_id: client_id} = config, refresh_token) do
    with {:ok, endpoints} <- discover(config, :token),
         {:ok, endpoint} <-
           require_endpoint(Map.get(endpoints, :token_endpoint), :no_token_endpoint),
         {:ok, token_schema} <- DeviceCode.validate_token_response_schema(@token_response_schema),
         {:ok, response} <-
           DeviceCode.refresh(
             token_endpoint: endpoint,
             client_id: client_id,
             client_secret: Map.get(config, :client_secret),
             refresh_token: refresh_token,
             response_schema: token_schema,
             max_response_bytes:
               config_get(config, :max_response_bytes, @default_max_response_bytes),
             timeout_ms: config_get(config, :timeout_ms, @default_timeout_ms),
             allow_http: allow_http?(config),
             http_client: Map.get(config, :http_client)
           ) do
      {:ok, response}
    else
      {:error, reason} -> normalize_error(reason)
    end
  end

  # --- Private ---

  defp discover(%{issuer: issuer} = config, operation) do
    opts =
      %{
        allow_http: allow_http?(config),
        endpoints: Map.get(config, :endpoints),
        trusted_origins: Map.get(config, :trusted_origins, []),
        http_client: Map.get(config, :http_client),
        for: operation
      }
      |> maybe_put(
        :timeout_ms,
        config_get(config, :discovery_timeout_ms, @default_discovery_timeout_ms)
      )
      |> maybe_put(
        :max_response_bytes,
        config_get(config, :discovery_max_response_bytes, @default_discovery_max_response_bytes)
      )

    Discovery.discover(issuer, opts)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Map.put(opts, key, value)

  defp require_endpoint(endpoint, _reason) when is_binary(endpoint) and endpoint != "",
    do: {:ok, endpoint}

  defp require_endpoint(_endpoint, reason), do: {:error, reason}

  defp allow_http?(config), do: Map.get(config, :allow_http, false) == true

  defp validate_scope_options(config) do
    if not is_nil(Map.get(config, :scope)) and not is_nil(Map.get(config, :scopes)),
      do: {:error, {:invalid_scope_options, :scope_and_scopes}},
      else: :ok
  end

  defp scopes_for(config) do
    if is_nil(Map.get(config, :scope)),
      do: Map.get(config, :scopes, @default_scopes),
      else: nil
  end

  defp config_get(config, key, default) do
    case Map.get(config, key) do
      nil -> default
      value -> value
    end
  end

  defp normalize_error({:timeout, _ms} = reason), do: {:error, {:http_request_failed, reason}}

  defp normalize_error({:transport_error, _reason} = reason),
    do: {:error, {:http_request_failed, reason}}

  defp normalize_error({:response_bytes_exceeded, _max} = reason), do: {:error, reason}
  defp normalize_error({:invalid_response, _reason} = reason), do: {:error, reason}
  defp normalize_error(reason), do: {:error, reason}
end
