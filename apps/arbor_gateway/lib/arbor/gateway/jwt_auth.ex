defmodule Arbor.Gateway.JwtAuth do
  @moduledoc """
  JWT bearer token authentication plug for the Gateway.

  Tries to verify an `Authorization: Bearer <token>` as a JWT signed by
  a configured OIDC provider. On success, derives an `agent_id` from the
  token claims and assigns it to `conn.assigns.agent_id`.

  On failure (not a JWT, expired, wrong issuer, etc.), passes through
  without modification — letting the existing `Arbor.Gateway.Auth` API
  key plug handle authentication as fallback.

  This is additive and non-breaking: API key auth continues to work for
  machine-to-machine clients.
  """

  import Plug.Conn

  alias Arbor.Security.OIDC.{Config, IdentityStore, TokenVerifier}

  require Logger

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, token} <- extract_bearer_token(conn),
         {:ok, provider} <- find_matching_provider(token),
         {:ok, claims} <- TokenVerifier.verify(token, provider) do
      agent_id = IdentityStore.derive_agent_id(claims)

      conn
      |> assign(:agent_id, agent_id)
      |> assign(:jwt_authenticated, true)
    else
      _ ->
        # Not a valid JWT — pass through to API key auth
        conn
    end
  end

  # --- Private ---

  defp extract_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        token = String.trim(token)

        # Quick check: JWTs have 3 dot-separated parts
        case String.split(token, ".") do
          [_, _, _] -> {:ok, token}
          _ -> :not_jwt
        end

      _ ->
        :no_bearer
    end
  end

  defp find_matching_provider(token) do
    providers = Config.providers()

    if providers == [] do
      :no_providers
    else
      # Try to match token's issuer to a configured provider
      case TokenVerifier.decode_unverified(token) do
        {:ok, %{"iss" => iss}} ->
          case Enum.find(providers, fn p -> Map.get(p, :issuer) == iss end) do
            nil -> :no_matching_provider
            provider -> {:ok, provider}
          end

        _ ->
          # Can't decode — try first provider as fallback
          {:ok, List.first(providers)}
      end
    end
  end
end
