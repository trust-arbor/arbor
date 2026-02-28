defmodule Arbor.Security.OIDC.AuthCodeFlow do
  @moduledoc """
  OIDC Authorization Code + PKCE flow for browser-based authentication.

  Implements the three steps of the authorization code flow:
  1. `build_authorize_url/4` - constructs the OIDC authorize URL with PKCE
  2. `exchange_code/4` - exchanges the authorization code for tokens
  3. `generate_pkce/0` - creates code_verifier + code_challenge pair

  Uses existing `TokenVerifier` for id_token validation and `Req` for HTTP.
  No additional dependencies needed.
  """

  require Logger

  @doc """
  Generate a PKCE code verifier and code challenge.

  Returns `{code_verifier, code_challenge}` where:
  - `code_verifier` is a 43-char base64url random string
  - `code_challenge` is SHA-256 hash of verifier, base64url encoded

  See RFC 7636.
  """
  @spec generate_pkce() :: {String.t(), String.t()}
  def generate_pkce do
    verifier =
      :crypto.strong_rand_bytes(32)
      |> Base.url_encode64(padding: false)

    challenge =
      :crypto.hash(:sha256, verifier)
      |> Base.url_encode64(padding: false)

    {verifier, challenge}
  end

  @doc """
  Generate a cryptographic random state parameter for CSRF protection.
  """
  @spec generate_state() :: String.t()
  def generate_state do
    :crypto.strong_rand_bytes(16)
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Build the OIDC authorization URL with PKCE parameters.

  Discovers the `authorization_endpoint` from the provider's
  `.well-known/openid-configuration`.

  ## Parameters

  - `provider` - map with `:issuer` and `:client_id`
  - `redirect_uri` - the callback URL
  - `state` - CSRF state parameter
  - `opts` - optional overrides:
    - `:scopes` - list of scopes (default: `["openid", "email", "profile"]`)
    - `:code_challenge` - pre-generated PKCE challenge
    - `:code_challenge_method` - default `"S256"`

  Returns `{:ok, authorize_url, code_verifier}` or `{:error, reason}`.
  """
  @spec build_authorize_url(map(), String.t(), String.t(), keyword()) ::
          {:ok, String.t(), String.t()} | {:error, term()}
  def build_authorize_url(
        %{issuer: issuer, client_id: client_id} = _provider,
        redirect_uri,
        state,
        opts \\ []
      ) do
    scopes = Keyword.get(opts, :scopes, ["openid", "email", "profile"])

    {code_verifier, code_challenge} =
      case Keyword.get(opts, :code_challenge) do
        nil -> generate_pkce()
        challenge -> {Keyword.get(opts, :code_verifier, ""), challenge}
      end

    with {:ok, oidc_config} <- fetch_openid_configuration(issuer),
         {:ok, auth_endpoint} <- get_authorization_endpoint(oidc_config) do
      params =
        URI.encode_query(%{
          "response_type" => "code",
          "client_id" => client_id,
          "redirect_uri" => redirect_uri,
          "scope" => Enum.join(scopes, " "),
          "state" => state,
          "code_challenge" => code_challenge,
          "code_challenge_method" => Keyword.get(opts, :code_challenge_method, "S256")
        })

      url = "#{auth_endpoint}?#{params}"
      {:ok, url, code_verifier}
    end
  end

  @doc """
  Exchange an authorization code for tokens.

  POSTs to the provider's token endpoint with `grant_type=authorization_code`
  and PKCE code_verifier.

  Returns `{:ok, token_response}` with `"id_token"`, `"access_token"`, etc.
  """
  @spec exchange_code(map(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def exchange_code(
        %{issuer: issuer, client_id: client_id} = provider,
        code,
        redirect_uri,
        code_verifier
      ) do
    with {:ok, oidc_config} <- fetch_openid_configuration(issuer),
         token_endpoint when is_binary(token_endpoint) <- Map.get(oidc_config, "token_endpoint") do
      body = %{
        "grant_type" => "authorization_code",
        "client_id" => client_id,
        "code" => code,
        "redirect_uri" => redirect_uri,
        "code_verifier" => code_verifier
      }

      body =
        case Map.get(provider, :client_secret) do
          nil -> body
          secret -> Map.put(body, "client_secret", secret)
        end

      case Req.post(token_endpoint, form: body, receive_timeout: 10_000) do
        {:ok, %{status: 200, body: response}} when is_map(response) ->
          {:ok, response}

        {:ok, %{status: status, body: body}} ->
          {:error, {:token_exchange_failed, status, body}}

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

  defp get_authorization_endpoint(oidc_config) do
    case Map.get(oidc_config, "authorization_endpoint") do
      nil -> {:error, :no_authorization_endpoint}
      endpoint -> {:ok, endpoint}
    end
  end
end
