defmodule Arbor.Security.OIDC.DeviceFlow do
  @moduledoc """
  RFC 8628 Device Authorization Grant for CLI authentication.

  Implements the three-phase device flow:
  1. `start/1` — request device + user codes from the authorization server
  2. `poll/2` — poll the token endpoint until the user authorizes
  3. `refresh/2` — refresh an expired access token

  All functions are pure I/O — no GenServer or persistent state needed.
  """

  require Logger

  @default_poll_interval 5
  @default_timeout_ms :timer.minutes(5)

  @doc """
  Start the device authorization flow.

  Fetches the provider's OpenID Configuration to discover the
  `device_authorization_endpoint`, then requests device + user codes.

  Returns `{:ok, device_response}` with:
  - `:device_code` — opaque code for polling
  - `:user_code` — code the user enters in browser
  - `:verification_uri` — URL for the user to visit
  - `:verification_uri_complete` — URL with code pre-filled (optional)
  - `:interval` — polling interval in seconds
  - `:expires_in` — lifetime of the device code in seconds
  """
  @spec start(map()) :: {:ok, map()} | {:error, term()}
  def start(%{issuer: issuer, client_id: client_id} = config) do
    scopes = Map.get(config, :scopes, ["openid", "email", "profile"])

    with {:ok, oidc_config} <- fetch_openid_configuration(issuer),
         {:ok, device_endpoint} <- get_device_endpoint(oidc_config) do
      request_device_code(device_endpoint, client_id, scopes)
    end
  end

  @doc """
  Poll the token endpoint until the user authorizes or the flow expires.

  Blocks the current process. Returns `{:ok, token_response}` on success
  with `:access_token`, `:id_token`, `:refresh_token`, `:expires_in`.
  """
  @spec poll(map(), map()) :: {:ok, map()} | {:error, term()}
  def poll(%{issuer: issuer, client_id: client_id} = _config, device_response) do
    device_code = device_response["device_code"] || device_response[:device_code]
    interval = device_response["interval"] || device_response[:interval] || @default_poll_interval
    expires_in = device_response["expires_in"] || device_response[:expires_in] || 300
    deadline = System.monotonic_time(:millisecond) + min(expires_in * 1000, @default_timeout_ms)

    with {:ok, oidc_config} <- fetch_openid_configuration(issuer),
         token_endpoint when is_binary(token_endpoint) <- Map.get(oidc_config, "token_endpoint") do
      poll_loop(token_endpoint, client_id, device_code, interval, deadline)
    else
      nil -> {:error, :no_token_endpoint}
      {:error, _} = error -> error
    end
  end

  @doc """
  Refresh an access token using a refresh token.

  Returns `{:ok, token_response}` with new tokens.
  """
  @spec refresh(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def refresh(%{issuer: issuer, client_id: client_id}, refresh_token) do
    with {:ok, oidc_config} <- fetch_openid_configuration(issuer),
         token_endpoint when is_binary(token_endpoint) <- Map.get(oidc_config, "token_endpoint") do
      body = %{
        "grant_type" => "refresh_token",
        "client_id" => client_id,
        "refresh_token" => refresh_token
      }

      case Req.post(token_endpoint, form: body, receive_timeout: 10_000) do
        {:ok, %{status: 200, body: response}} when is_map(response) ->
          {:ok, response}

        {:ok, %{status: status, body: body}} ->
          {:error, {:token_refresh_failed, status, body}}

        {:error, reason} ->
          {:error, {:http_request_failed, reason}}
      end
    else
      nil -> {:error, :no_token_endpoint}
      {:error, _} = error -> error
    end
  end

  # --- Private ---

  defp fetch_openid_configuration(issuer) do
    url = String.trim_trailing(issuer, "/") <> "/.well-known/openid-configuration"

    case Req.get(url, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        Jason.decode(body)

      {:ok, %{status: status}} ->
        {:error, {:openid_config_fetch_failed, status}}

      {:error, reason} ->
        {:error, {:http_request_failed, reason}}
    end
  end

  defp get_device_endpoint(oidc_config) do
    case Map.get(oidc_config, "device_authorization_endpoint") do
      nil -> {:error, :no_device_authorization_endpoint}
      endpoint -> {:ok, endpoint}
    end
  end

  defp request_device_code(endpoint, client_id, scopes) do
    body = %{
      "client_id" => client_id,
      "scope" => Enum.join(scopes, " ")
    }

    case Req.post(endpoint, form: body, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: response}} when is_map(response) ->
        {:ok, response}

      {:ok, %{status: status, body: body}} ->
        {:error, {:device_code_request_failed, status, body}}

      {:error, reason} ->
        {:error, {:http_request_failed, reason}}
    end
  end

  defp poll_loop(token_endpoint, client_id, device_code, interval, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :device_flow_expired}
    else
      body = %{
        "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
        "client_id" => client_id,
        "device_code" => device_code
      }

      case Req.post(token_endpoint, form: body, receive_timeout: 10_000) do
        {:ok, %{status: 200, body: response}} when is_map(response) ->
          {:ok, response}

        {:ok, %{status: status, body: %{"error" => error} = body}} when status in [400, 428] ->
          handle_poll_error(error, body, token_endpoint, client_id, device_code, interval, deadline)

        {:ok, %{status: status, body: body}} ->
          {:error, {:token_request_failed, status, body}}

        {:error, reason} ->
          {:error, {:http_request_failed, reason}}
      end
    end
  end

  defp handle_poll_error("authorization_pending", _body, token_endpoint, client_id, device_code, interval, deadline) do
    Process.sleep(interval * 1000)
    poll_loop(token_endpoint, client_id, device_code, interval, deadline)
  end

  defp handle_poll_error("slow_down", _body, token_endpoint, client_id, device_code, interval, deadline) do
    # RFC 8628 §3.5: increase interval by 5 seconds
    new_interval = interval + 5
    Process.sleep(new_interval * 1000)
    poll_loop(token_endpoint, client_id, device_code, new_interval, deadline)
  end

  defp handle_poll_error("expired_token", _body, _token_endpoint, _client_id, _device_code, _interval, _deadline) do
    {:error, :device_code_expired}
  end

  defp handle_poll_error("access_denied", _body, _token_endpoint, _client_id, _device_code, _interval, _deadline) do
    {:error, :access_denied}
  end

  defp handle_poll_error(error, body, _token_endpoint, _client_id, _device_code, _interval, _deadline) do
    {:error, {:device_flow_error, error, body}}
  end
end
