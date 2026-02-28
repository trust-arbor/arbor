defmodule Arbor.Dashboard.OidcAuth do
  @moduledoc """
  OIDC authentication plug for the Arbor Dashboard.

  Replaces HTTP Basic Auth with OIDC Authorization Code + PKCE flow.

  ## Routes handled

  - `GET /auth/login` — redirects to OIDC provider
  - `GET /auth/callback` — handles provider callback, establishes session
  - `GET /auth/logout` — clears session

  ## Behavior

  - If OIDC is configured and user has no session → redirect to `/auth/login`
  - If OIDC is configured and user has session → pass through with `current_agent_id` assign
  - If OIDC is not configured → open access (dev/test), same as previous Basic Auth behavior
  """

  import Plug.Conn

  alias Arbor.Security.OIDC.{AuthCodeFlow, Config, IdentityStore, TokenVerifier}

  require Logger

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{request_path: "/auth/login"} = conn, _opts) do
    handle_login(conn)
  end

  def call(%{request_path: "/auth/callback"} = conn, _opts) do
    handle_callback(conn)
  end

  def call(%{request_path: "/auth/logout"} = conn, _opts) do
    handle_logout(conn)
  end

  def call(conn, _opts) do
    case oidc_provider() do
      nil ->
        # OIDC not configured — open access (dev/test)
        conn

      _provider ->
        conn = fetch_session(conn)

        case get_session(conn, "agent_id") do
          nil ->
            return_to = conn.request_path <> encode_query_string(conn)

            conn
            |> put_session("return_to", return_to)
            |> redirect_to("/auth/login")
            |> halt()

          agent_id ->
            assign(conn, :current_agent_id, agent_id)
        end
    end
  end

  # --- Route handlers ---

  defp handle_login(conn) do
    case oidc_provider() do
      nil ->
        conn
        |> send_resp(404, "OIDC not configured")
        |> halt()

      provider ->
        state = AuthCodeFlow.generate_state()
        redirect_uri = callback_uri(conn)

        case AuthCodeFlow.build_authorize_url(provider, redirect_uri, state) do
          {:ok, authorize_url, code_verifier} ->
            conn
            |> fetch_session()
            |> put_session("oidc_state", state)
            |> put_session("oidc_code_verifier", code_verifier)
            |> redirect_to(authorize_url)
            |> halt()

          {:error, reason} ->
            Logger.error("[OidcAuth] Failed to build authorize URL: #{inspect(reason)}")

            conn
            |> send_resp(502, "Failed to reach OIDC provider")
            |> halt()
        end
    end
  end

  defp handle_callback(conn) do
    case oidc_provider() do
      nil ->
        conn
        |> send_resp(404, "OIDC not configured")
        |> halt()

      provider ->
        conn = conn |> fetch_session() |> fetch_query_params()
        params = conn.query_params
        stored_state = get_session(conn, "oidc_state")
        code_verifier = get_session(conn, "oidc_code_verifier")

        with :ok <- verify_state(params["state"], stored_state),
             {:ok, token_response} <-
               AuthCodeFlow.exchange_code(
                 provider,
                 params["code"],
                 callback_uri(conn),
                 code_verifier
               ),
             {:ok, claims} <-
               TokenVerifier.verify(token_response["id_token"], provider),
             {:ok, identity, _status} <- IdentityStore.load_or_create(claims) do
          # Ensure human has capabilities via role assignment
          ensure_role(identity.agent_id)

          return_to = get_session(conn, "return_to") || "/"

          conn
          |> delete_session("oidc_state")
          |> delete_session("oidc_code_verifier")
          |> delete_session("return_to")
          |> put_session("agent_id", identity.agent_id)
          |> redirect_to(return_to)
          |> halt()
        else
          {:error, reason} ->
            Logger.error("[OidcAuth] Callback failed: #{inspect(reason)}")

            conn
            |> delete_session("oidc_state")
            |> delete_session("oidc_code_verifier")
            |> send_resp(401, "Authentication failed")
            |> halt()
        end
    end
  end

  defp handle_logout(conn) do
    conn
    |> fetch_session()
    |> configure_session(drop: true)
    |> redirect_to("/")
    |> halt()
  end

  # --- Helpers ---

  defp verify_state(nil, _stored), do: {:error, :missing_state}
  defp verify_state(_given, nil), do: {:error, :no_stored_state}

  defp verify_state(given, stored) do
    if Plug.Crypto.secure_compare(given, stored) do
      :ok
    else
      {:error, :state_mismatch}
    end
  end

  defp ensure_role(agent_id) do
    if Code.ensure_loaded?(Arbor.Security) do
      role = Arbor.Security.OIDC.Config.get() |> Keyword.get(:default_role, :admin)

      case apply(Arbor.Security, :assign_role, [agent_id, role]) do
        {:ok, _caps} ->
          :ok

        {:error, reason} ->
          Logger.warning("[OidcAuth] Role assignment failed: #{inspect(reason)}")
      end
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp oidc_provider do
    case Config.providers() do
      [provider | _] -> provider
      _ -> nil
    end
  end

  defp callback_uri(conn) do
    scheme = if conn.scheme == :https, do: "https", else: "http"
    host = conn.host
    port_suffix = port_suffix(conn.scheme, conn.port)
    "#{scheme}://#{host}#{port_suffix}/auth/callback"
  end

  defp port_suffix(:https, 443), do: ""
  defp port_suffix(:http, 80), do: ""
  defp port_suffix(_, port), do: ":#{port}"

  defp redirect_to(conn, url) do
    conn
    |> put_resp_header("location", url)
    |> send_resp(302, "")
  end

  defp encode_query_string(%{query_string: ""}), do: ""
  defp encode_query_string(%{query_string: qs}), do: "?" <> qs
end
