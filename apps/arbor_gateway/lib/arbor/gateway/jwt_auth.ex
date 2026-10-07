defmodule Arbor.Gateway.JwtAuth do
  @moduledoc """
  JWT bearer token authentication plug for the Gateway.

  Tries to authenticate an `Authorization: Bearer <token>` through the
  `Arbor.Security` OIDC boundary. The Security facade verifies the token,
  applies registration policy, and binds it to a registered identity. This
  plug additionally requires that identity to remain active before assigning
  it to `conn.assigns.agent_id`.

  On failure (not a JWT, expired, wrong issuer, etc.), passes through
  without modification — letting the existing `Arbor.Gateway.Auth` API
  key plug handle authentication as fallback.

  This is additive and non-breaking: API key auth continues to work for
  machine-to-machine clients.
  """

  import Plug.Conn

  alias Arbor.Security

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    security = Keyword.get(opts, :security_facade, Security)

    with {:ok, token} <- extract_bearer_token(conn),
         {:ok, agent_id} <- authenticate_registered_principal(token, security) do
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

  defp authenticate_registered_principal(token, security) do
    case safe_authenticate_token(security, token) do
      {:ok, agent_id, authority} ->
        admission = active_registered_identity(security, agent_id)
        closure = close_temporary_authority(security, authority)

        case {admission, closure} do
          {:ok, :ok} -> {:ok, agent_id}
          _ -> {:error, :oidc_principal_unauthorized}
        end

      _ ->
        {:error, :oidc_principal_unauthorized}
    end
  end

  defp safe_authenticate_token(security, token) do
    security.authenticate_oidc_token(token)
  rescue
    _ -> {:error, :oidc_authentication_unavailable}
  catch
    _, _ -> {:error, :oidc_authentication_unavailable}
  end

  defp active_registered_identity(security, agent_id) when is_binary(agent_id) do
    if security.identity_active?(agent_id),
      do: :ok,
      else: {:error, :oidc_identity_not_active}
  rescue
    _ -> {:error, :identity_registry_unavailable}
  catch
    _, _ -> {:error, :identity_registry_unavailable}
  end

  defp active_registered_identity(_security, _agent_id),
    do: {:error, :invalid_oidc_principal}

  defp close_temporary_authority(security, authority) do
    case security.close_signing_authority(authority) do
      :ok -> :ok
      _ -> {:error, :oidc_authority_close_failed}
    end
  rescue
    _ -> {:error, :oidc_authority_close_failed}
  catch
    _, _ -> {:error, :oidc_authority_close_failed}
  end
end
