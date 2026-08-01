defmodule Arbor.LLM.OAuth.Login do
  @moduledoc """
  Redacted, provider-specific OAuth acquisition coordinator.

  Owns exactly two closed flows -- OpenAI authorization-code + PKCE, and xAI
  RFC 8628 device-code -- built on top of the provider-neutral
  `Arbor.Common.OAuth.{AuthCode, DeviceCode}` primitives and the closed
  `Arbor.LLM.OAuth.ProviderPolicy` table. There is no caller-supplied
  endpoint, provider alias, flow-mode, or HTTP transport parameter anywhere
  in this module: every endpoint, client identity, and scope is a pinned
  compile-time constant, and every outbound HTTP call resolves its adapter
  through `Arbor.Common.OAuth.HttpClient`'s existing application-config seam
  (never a per-call override), so a production caller cannot redirect where
  token exchange or device polling goes over the wire.

  `start_openai_login/1` and `start_xai_device_login/0` return an opaque,
  one-shot correlation handle (backed by `Arbor.LLM.OAuth.Login.PendingStore`,
  a supervised in-process GenServer) instead of the raw flow state, so a
  forged, replayed, or expired handle fails `complete_*` closed before any
  HTTP call or publication. On success, `complete_openai_login/3` and
  `complete_xai_device_login/1` publish exclusively through
  `Arbor.LLM.OAuth.publish_arbor_owned/2` -- this module never writes the
  credential store directly -- and return `:ok` only; the acquired token
  material is never returned, logged, or stored anywhere else.

  Public entry points are exposed through `Arbor.LLM` as
  `start_openai_login/1`, `complete_openai_login/3`,
  `start_xai_device_login/0`, and `complete_xai_device_login/1`.

  This slice does not implement a browser launcher, a callback HTTP
  listener, a dashboard UI, or an operator CLI -- `complete_openai_login/3`
  takes `code`/`state` as plain arguments a future out-of-scope caller
  obtains however it wants.
  """

  alias Arbor.Common.OAuth.AuthCode
  alias Arbor.Common.OAuth.DeviceCode
  alias Arbor.LLM.Endpoint
  alias Arbor.LLM.OAuth
  alias Arbor.LLM.OAuth.AcquiredCredential
  alias Arbor.LLM.OAuth.JwtPayload
  alias Arbor.LLM.OAuth.Login.AuthorizationPrompt
  alias Arbor.LLM.OAuth.Login.DevicePrompt
  alias Arbor.LLM.OAuth.Login.PendingStore
  alias Arbor.LLM.OAuth.ProviderPolicy

  # OpenAI's authorization-code lifetime is not published by this endpoint;
  # 10 minutes is generous for a human completing a browser redirect and
  # short for an attacker.
  @openai_handle_ttl_ms 600_000

  # DeviceCode.poll/1's internal deadline is min(poll_timeout_ms, expires_in
  # * 1000), and poll_timeout_ms is itself bounded well under this by the
  # provider-neutral primitive. Clamping the window we request here keeps us
  # inside that bound regardless of how long xAI's real device_code TTL is;
  # it can only make polling stop no later than the true issuance-anchored
  # deadline, never later.
  @xai_max_poll_window_ms 1_000_000

  @start_openai_option_keys MapSet.new([:redirect_uri])
  @default_redirect_uri_selector :port_1455
  @xai_refresh_token_min_bytes 1
  @xai_refresh_token_max_bytes 65_536

  @openai_token_response_schema %{
    "access_token" => :required_string,
    "refresh_token" => :required_string,
    "id_token" => :required_string,
    "token_type" => :optional_string,
    "expires_in" => :optional_integer
  }

  @xai_token_response_schema %{
    "access_token" => :required_string,
    "refresh_token" => :optional_string,
    "token_type" => :optional_string,
    "expires_in" => :optional_integer
  }

  @doc """
  Start the OpenAI authorization-code + PKCE flow.

  `opts[:redirect_uri]` selects between the two pinned Codex-CLI-compatible
  localhost callback ports (`:port_1455` default, or `:port_1457`); any
  other value, including a raw string, is refused before any PKCE/state
  material is generated or stored.
  """
  @spec start_openai_login(keyword()) :: {:ok, AuthorizationPrompt.t()} | {:error, term()}
  def start_openai_login(opts \\ []) do
    policy = ProviderPolicy.openai()

    with {:ok, selector} <- validate_openai_start_options(opts),
         {:ok, redirect_uri} <- fetch_redirect_uri(policy, selector),
         {:ok, _canonical} <-
           Endpoint.validate(policy.authorization_endpoint, :oauth_openai_authorize),
         {:ok, pending} <-
           PendingStore.issue_openai(selector, monotonic_ms() + @openai_handle_ttl_ms),
         {:ok, authorize_url} <-
           AuthCode.build_authorize_url(
             authorization_endpoint: policy.authorization_endpoint,
             client_id: policy.client_id,
             redirect_uri: redirect_uri,
             scopes: policy.scopes,
             state: pending.state,
             code_challenge: pending.code_challenge,
             code_challenge_method: policy.code_challenge_method
           ) do
      {:ok, %AuthorizationPrompt{authorize_url: authorize_url, handle: pending.handle}}
    end
  end

  @doc """
  Complete the OpenAI authorization-code + PKCE flow.

  Order is fail-closed at every step: an unknown, replayed, or expired
  `handle` fails before `state` is even compared; a `state` mismatch fails
  before any HTTP call; the redirect URI and token endpoint are re-derived
  fresh from `Arbor.LLM.OAuth.ProviderPolicy` (never trusted from the stored
  handle beyond a closed selector atom) and re-validated before the
  exchange; a missing or malformed `chatgpt_account_id` claim fails before
  publication. Returns `:ok` only -- the exchanged token material is never
  returned.
  """
  @spec complete_openai_login(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def complete_openai_login(handle, code, state) do
    policy = ProviderPolicy.openai()

    with {:ok, pending} <- fetch_pending_openai(handle),
         :ok <- verify_state(state, pending.state),
         {:ok, redirect_uri} <- fetch_redirect_uri(policy, pending.redirect_uri_selector),
         {:ok, _canonical} <- Endpoint.validate(policy.token_endpoint, :oauth_token),
         {:ok, tokens} <- exchange_openai_code(policy, redirect_uri, pending.code_verifier, code),
         {:ok, account_id} <- extract_openai_account_id(tokens),
         {:ok, credential} <- build_openai_credential(account_id, tokens) do
      OAuth.publish_arbor_owned(:openai_oauth, credential)
    end
  end

  @doc "Start the xAI RFC 8628 device-code flow."
  @spec start_xai_device_login() :: {:ok, DevicePrompt.t()} | {:error, term()}
  def start_xai_device_login do
    policy = ProviderPolicy.xai()

    with {:ok, _canonical} <-
           Endpoint.validate(
             policy.device_authorization_endpoint,
             :oauth_xai_device_authorization
           ),
         {:ok, response} <-
           DeviceCode.start(
             device_authorization_endpoint: policy.device_authorization_endpoint,
             client_id: policy.client_id,
             scopes: policy.scopes,
             allow_http: false
           ),
         {:ok, %{handle: handle}} <- put_xai_pending(response) do
      {:ok,
       %DevicePrompt{
         user_code: Map.fetch!(response, "user_code"),
         verification_uri: Map.fetch!(response, "verification_uri"),
         verification_uri_complete: Map.get(response, "verification_uri_complete"),
         handle: handle
       }}
    end
  end

  @doc """
  Complete the xAI RFC 8628 device-code flow.

  An unknown, replayed, or already-expired `handle` fails before any HTTP
  call. The remaining poll window is computed from the issuance-time
  absolute deadline recorded at `start_xai_device_login/0` -- time already
  elapsed between start and complete is subtracted, never reset by this
  call. Terminal RFC 8628 errors are inherited closed and body-free from
  `Arbor.Common.OAuth.DeviceCode`. Returns `:ok` only.
  """
  @spec complete_xai_device_login(String.t()) :: :ok | {:error, term()}
  def complete_xai_device_login(handle) do
    policy = ProviderPolicy.xai()

    with {:ok, pending} <- fetch_pending_xai(handle),
         {:ok, window_ms} <- remaining_window(pending.deadline_ms),
         {:ok, _canonical} <- Endpoint.validate(policy.token_endpoint, :oauth_xai_token),
         {:ok, tokens} <- poll_xai(policy, pending, window_ms),
         {:ok, refresh_token} <- require_xai_refresh_token(tokens),
         {:ok, credential} <- build_xai_credential(refresh_token, tokens) do
      OAuth.publish_arbor_owned(:xai_oauth, credential)
    end
  end

  # -- OpenAI internals --------------------------------------------------

  defp fetch_redirect_uri(policy, selector) do
    case Map.fetch(policy.redirect_uris, selector) do
      {:ok, uri} -> {:ok, uri}
      :error -> {:error, :invalid_redirect_uri_selector}
    end
  end

  defp fetch_pending_openai(handle) do
    case PendingStore.take_openai(handle) do
      {:ok, pending} -> {:ok, pending}
      {:error, :not_found} -> {:error, :oauth_handle_invalid}
      {:error, :expired} -> {:error, :oauth_handle_expired}
    end
  end

  defp verify_state(received, expected) do
    case AuthCode.verify_state(received, expected) do
      :ok -> :ok
      {:error, :state_mismatch} -> {:error, :oauth_state_mismatch}
    end
  end

  defp exchange_openai_code(policy, redirect_uri, code_verifier, code) do
    AuthCode.exchange_code(
      token_endpoint: policy.token_endpoint,
      client_id: policy.client_id,
      code: code,
      redirect_uri: redirect_uri,
      code_verifier: code_verifier,
      response_schema: @openai_token_response_schema
    )
  end

  # Bounded, non-authentication read of a self-asserted claim from a token
  # response obtained via a direct, Endpoint-validated TLS POST to the
  # trusted token endpoint -- not a redirect-carried value and not
  # signature-verified. This is never treated as an authentication decision.
  defp extract_openai_account_id(%{"id_token" => id_token}) when is_binary(id_token) do
    with {:ok, payload} <- JwtPayload.decode(id_token),
         %{"chatgpt_account_id" => account_id} <-
           Map.get(payload, "https://api.openai.com/auth"),
         true <- is_binary(account_id) do
      {:ok, account_id}
    else
      _ -> {:error, :oauth_account_identity_missing}
    end
  end

  defp extract_openai_account_id(_tokens), do: {:error, :oauth_account_identity_missing}

  defp build_openai_credential(account_id, tokens) do
    AcquiredCredential.new(%{
      provider: :openai,
      account_id: account_id,
      access_token: Map.get(tokens, "access_token"),
      refresh_token: Map.get(tokens, "refresh_token")
    })
  end

  # -- xAI internals -------------------------------------------------------

  defp put_xai_pending(response) do
    deadline_ms = monotonic_ms() + Map.fetch!(response, "expires_in") * 1_000

    PendingStore.issue_xai(
      Map.fetch!(response, "device_code"),
      Map.fetch!(response, "interval"),
      deadline_ms
    )
  end

  defp fetch_pending_xai(handle) do
    case PendingStore.take_xai(handle) do
      {:ok, pending} -> {:ok, pending}
      {:error, :not_found} -> {:error, :oauth_handle_invalid}
      {:error, :expired} -> {:error, :oauth_handle_expired}
    end
  end

  defp remaining_window(deadline_ms) do
    remaining_ms = deadline_ms - monotonic_ms()

    if remaining_ms > 0,
      do: {:ok, min(remaining_ms, @xai_max_poll_window_ms)},
      else: {:error, :oauth_device_flow_expired}
  end

  defp poll_xai(policy, pending, window_ms) do
    DeviceCode.poll(
      token_endpoint: policy.token_endpoint,
      client_id: policy.client_id,
      device_code: pending.device_code,
      interval: pending.interval,
      expires_in: div(window_ms + 999, 1_000),
      poll_timeout_ms: window_ms,
      response_schema: @xai_token_response_schema
    )
  end

  defp require_xai_refresh_token(tokens) do
    case Map.get(tokens, "refresh_token") do
      value when is_binary(value) ->
        trimmed = String.trim(value)

        if byte_size(trimmed) >= @xai_refresh_token_min_bytes and
             byte_size(trimmed) <= @xai_refresh_token_max_bytes do
          {:ok, value}
        else
          {:error, :oauth_refresh_token_required}
        end

      _ ->
        {:error, :oauth_refresh_token_required}
    end
  end

  defp build_xai_credential(refresh_token, tokens) do
    AcquiredCredential.new(%{
      provider: :xai,
      account_id: nil,
      access_token: Map.get(tokens, "access_token"),
      refresh_token: refresh_token
    })
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp validate_openai_start_options(opts) when is_list(opts) do
    with {:ok, normalized} <- validate_openai_start_option_pairs(opts, %{}) do
      {:ok, Map.get(normalized, :redirect_uri, @default_redirect_uri_selector)}
    end
  end

  defp validate_openai_start_options(_opts), do: {:error, :keyword_options_required}

  defp validate_openai_start_option_pairs([], acc), do: {:ok, acc}

  defp validate_openai_start_option_pairs([{key, value} | rest], acc)
       when is_atom(key) do
    if MapSet.member?(@start_openai_option_keys, key) do
      if Map.has_key?(acc, key) do
        {:error, :duplicate_login_option}
      else
        validate_openai_start_option_pairs(rest, Map.put(acc, key, value))
      end
    else
      {:error, :unknown_login_option}
    end
  end

  defp validate_openai_start_option_pairs(_bad, _acc), do: {:error, :improper_openai_options}
end
