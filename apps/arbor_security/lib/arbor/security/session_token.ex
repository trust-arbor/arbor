defmodule Arbor.Security.SessionToken do
  @moduledoc """
  Signed session tokens for human identity verification.

  When a human authenticates via OIDC, a session token is generated and
  signed by the SystemAuthority. This token proves that a LiveView process
  or API call was initiated by an authenticated human, without requiring
  per-call Ed25519 signing (which agents use).

  ## Token Format

  Wire format (C4 review, 2026-06-09): `base64url(hmac <> payload_bytes)`,
  where `payload_bytes = term_to_binary(payload)` and `hmac` is a fixed
  32-byte HMAC-SHA256 over `payload_bytes`. The HMAC is verified over the
  EXACT transported `payload_bytes` BEFORE any `binary_to_term`, so:

    1. An attacker cannot make us deserialize arbitrary bytes without
       already knowing the secret (closes the pre-authentication
       `binary_to_term` DoS surface).
    2. The signature covers the literal transported bytes, not a
       re-serialization — so an OTP `term_to_binary` encoding change can't
       silently invalidate live sessions.

  The payload is a map containing:
  - `pid` — the human's `human_<hash>` identity
  - `sid` — unique session identifier
  - `iat` / `exp` — issued-at / expiry (unix seconds)
  - `v` — payload schema version

  ## Usage

      # Generate during an authenticated OIDC callback
      {:ok, token} =
        Arbor.Security.issue_human_session_token("human_abc123", authority)

      # Verify in authorize calls
      {:ok, principal_id} = SessionToken.verify(token)

      # Pass to Security.authorize
      Security.authorize(principal_id, resource, action, session_token: token)
  """

  require Logger

  @default_ttl_seconds 3_600
  @token_version 2
  @approval_authority_ttl_seconds 300
  @production_scopes [
    "arbor://agent",
    "arbor://approval",
    "arbor://chat",
    "arbor://comms",
    "arbor://conversation",
    "arbor://orchestrator",
    "arbor://signals",
    "arbor://task",
    "arbor://template",
    "arbor://trust",
    "arbor://voice",
    "arbor://workspace"
  ]
  @default_scopes if(Mix.env() == :test,
                    do: ["arbor://test" | @production_scopes],
                    else: @production_scopes
                  )
  @known_insecure_secret "arbor-dev-session-token-secret-change-in-prod"
  # Bound before Base64/HMAC work. Comfortably exceeds generated tokens.
  @max_token_bytes 4096

  @doc """
  Validate the process-wide token secret before the security application starts.

  Session authentication must never start with a missing, short, or repository-
  known secret. Runtime configuration should supply at least 32 bytes through
  `ARBOR_SESSION_TOKEN_SECRET`.
  """
  @spec configuration_status() :: :ok | {:error, atom()}
  def configuration_status do
    case Application.get_env(:arbor_security, :session_token_secret) do
      secret when is_binary(secret) and byte_size(secret) >= 32 ->
        if secret == @known_insecure_secret,
          do: {:error, :insecure_session_token_secret},
          else: :ok

      nil ->
        {:error, :session_token_secret_missing}

      _ ->
        {:error, :invalid_session_token_secret}
    end
  end

  if Mix.env() == :test do
    @doc false
    @spec generate(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
    def generate(principal_id, opts \\ [])

    def generate(principal_id, opts) when is_binary(principal_id) do
      with :ok <- validate_generate_options(opts) do
        do_generate(principal_id, opts, :fixture)
      end
    end

    def generate(_principal_id, _opts), do: {:error, :invalid_principal}
  else
    @doc false
    @spec generate(term(), term()) :: {:error, :session_token_issuance_unauthorized}
    def generate(_principal_id, _opts \\ []),
      do: {:error, :session_token_issuance_unauthorized}
  end

  @doc false
  @spec generate_authorized(String.t(), term(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def generate_authorized(principal_id, authority, opts)
      when is_binary(principal_id) and is_list(opts) do
    with :ok <- validate_generate_options(opts),
         {:ok, ^principal_id} <- Arbor.Security.signing_authority_principal(authority) do
      do_generate(principal_id, opts, {:authority, authority})
    else
      _ -> {:error, :session_token_issuance_unauthorized}
    end
  end

  def generate_authorized(_principal_id, _authority, _opts),
    do: {:error, :session_token_issuance_unauthorized}

  defp do_generate(principal_id, opts, registry_authorization) do
    ttl = min(Keyword.get(opts, :ttl, @default_ttl_seconds), @default_ttl_seconds)
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, ttl, :second)
    session_id = Keyword.get(opts, :session_id, generate_session_id())

    with {:ok, expires_at} <- cap_expiry(expires_at, now, opts),
         :ok <- validate_session_id(session_id),
         scopes <- default_scopes(),
         :ok <-
           register_human_session(
             registry_authorization,
             session_id,
             principal_id,
             DateTime.to_unix(expires_at)
           ) do
      payload = %{
        v: @token_version,
        pid: principal_id,
        sid: session_id,
        iat: DateTime.to_unix(now),
        exp: DateTime.to_unix(expires_at),
        purpose: :human_session,
        scopes: scopes
      }

      # Sign the EXACT bytes that get transported — never a re-serialization.
      payload_bytes = :erlang.term_to_binary(payload)
      signature = mac(payload_bytes)

      token = Base.url_encode64(signature <> payload_bytes, padding: false)

      {:ok, token}
    end
  end

  defp register_human_session({:authority, authority}, session_id, principal_id, expires_at) do
    Arbor.Security.SessionRegistry.issue_human(
      session_id,
      principal_id,
      expires_at,
      authority
    )
  end

  if Mix.env() == :test do
    defp register_human_session(:fixture, session_id, principal_id, expires_at) do
      Arbor.Security.SessionRegistry.issue_fixture(session_id, principal_id, expires_at)
    end
  end

  defp register_human_session(_authorization, _session_id, _principal_id, _expires_at),
    do: {:error, :session_token_issuance_unauthorized}

  defp cap_expiry(expires_at, now, opts) do
    case Keyword.fetch(opts, :max_expires_at) do
      :error ->
        {:ok, expires_at}

      {:ok, bound} when is_integer(bound) and bound >= 0 and bound <= 253_402_300_799 ->
        expires = min(DateTime.to_unix(expires_at), bound)

        if expires > DateTime.to_unix(now),
          do: DateTime.from_unix(expires),
          else: {:error, :invalid_expiry_bound}

      _ ->
        {:error, :invalid_expiry_bound}
    end
  end

  @doc false
  def generate_conversation(_principal, _target),
    do: {:error, :session_token_issuance_unauthorized}

  @doc false
  def generate_conversation_authorized(principal, target, receipt),
    do: do_generate_conversation(principal, target, {:receipt, receipt})

  @doc false
  def generate_terminal_conversation(principal, target),
    do: do_generate_conversation(principal, target, :terminal)

  if Mix.env() == :test do
    @doc false
    def generate_conversation_fixture(principal, target),
      do: do_generate_conversation(principal, target, :fixture)

    # Negative `ttl` is rejected. Tests that need an already-expired proof
    # resign a valid fixture with an expiry in the past.
    @doc false
    @spec generate_expired_fixture(String.t()) :: {:ok, binary()} | {:error, term()}
    def generate_expired_fixture(principal_id) when is_binary(principal_id) do
      with {:ok, token} <- generate(principal_id),
           {:ok, _signature, bytes} <- split_token(token),
           {:ok, payload} <- safe_decode_payload(bytes) do
        now = DateTime.to_unix(DateTime.utc_now())
        expired = %{payload | iat: now - 120, exp: now - 60}
        expired_bytes = :erlang.term_to_binary(expired)
        {:ok, Base.url_encode64(mac(expired_bytes) <> expired_bytes, padding: false)}
      else
        _ -> {:error, :invalid_token}
      end
    end
  end

  defp do_generate_conversation(principal, target, registry_authorization) do
    if conversation_id?(principal, "human_") and conversation_target?(target) do
      now = DateTime.to_unix(DateTime.utc_now())

      payload = %{
        v: 2,
        pid: principal,
        sid: generate_session_id(),
        iat: now,
        exp: now + 90,
        purpose: :conversation,
        target: target
      }

      with :ok <-
             register_conversation_session(
               registry_authorization,
               payload.sid,
               principal,
               target,
               payload.exp
             ) do
        bytes = :erlang.term_to_binary(payload)
        {:ok, Base.url_encode64(mac(bytes) <> bytes, padding: false)}
      end
    else
      {:error, :invalid_token_scope}
    end
  end

  defp register_conversation_session(
         {:receipt, receipt},
         session_id,
         principal,
         target,
         expires_at
       ) do
    Arbor.Security.SessionRegistry.issue_conversation(
      session_id,
      principal,
      target,
      expires_at,
      receipt
    )
  end

  defp register_conversation_session(:terminal, session_id, principal, target, expires_at) do
    Arbor.Security.SessionRegistry.issue_terminal_conversation(
      session_id,
      principal,
      target,
      expires_at
    )
  end

  if Mix.env() == :test do
    defp register_conversation_session(:fixture, session_id, principal, _target, expires_at) do
      Arbor.Security.SessionRegistry.issue_fixture(session_id, principal, expires_at)
    end
  end

  defp register_conversation_session(
         _authorization,
         _session_id,
         _principal,
         _target,
         _expires_at
       ),
       do: {:error, :session_token_issuance_unauthorized}

  @doc """
  Verify authentication for the actual resource and action.

  Version 2 human-session tokens carry a closed list of allowed URI namespaces.
  Conversation tokens can authenticate only `:chat` on their exact target;
  generic `verify/1` deliberately rejects them, so other token consumers cannot
  widen their scope. Version 1's all-resource bearer semantics are retired.
  """
  def verify_for(token, resource, action)
      when is_binary(token) and byte_size(token) > 0 and byte_size(token) <= @max_token_bytes do
    with {:ok, signature, bytes} <- split_token(token),
         :ok <- verify_mac(bytes, signature),
         {:ok, payload} <- safe_decode_payload(bytes),
         :ok <- check_scope(payload, resource, action),
         :ok <- check_expiry(payload),
         :ok <- check_session(payload) do
      {:ok, payload.pid}
    end
  end

  def verify_for(_, _, _), do: {:error, :invalid_token}

  defp check_scope(
         %{
           v: @token_version,
           purpose: :human_session,
           scopes: scopes,
           pid: principal,
           sid: sid,
           iat: issued,
           exp: expires
         } = payload,
         resource,
         action
       )
       when map_size(payload) == 7 and is_list(scopes) and is_binary(resource) do
    cond do
      not valid_general_claims?(principal, sid, issued, expires, scopes) ->
        {:error, :invalid_token_scope}

      approval_resource?(resource) and
          System.system_time(:second) - issued >
            @approval_authority_ttl_seconds ->
        {:error, :approval_token_too_old}

      Enum.any?(scopes, &scope_matches?(&1, resource, action)) ->
        :ok

      true ->
        {:error, :invalid_token_scope}
    end
  end

  defp check_scope(%{v: 1}, _, _), do: {:error, :legacy_session_token}

  defp check_scope(
         %{
           v: 2,
           purpose: :conversation,
           target: target,
           pid: principal,
           sid: sid,
           iat: issued,
           exp: expires
         } = payload,
         resource,
         :chat
       )
       when map_size(payload) == 7 do
    if conversation_id?(principal, "human_") and conversation_target?(target) and
         is_binary(sid) and byte_size(sid) == 32 and is_integer(issued) and
         is_integer(expires) and expires - issued == 90 and
         resource == "arbor://chat/agent/" <> target do
      :ok
    else
      {:error, :invalid_token_scope}
    end
  end

  defp check_scope(_, _, _), do: {:error, :invalid_token_scope}

  defp conversation_target?(target),
    do: conversation_id?(target, "agent_") or conversation_id?(target, "human_")

  defp conversation_id?(id, prefix) when is_binary(id) and byte_size(id) in 1..256,
    do:
      String.valid?(id) and String.starts_with?(id, prefix) and
        Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id) and byte_size(id) > byte_size(prefix)

  defp conversation_id?(_, _), do: false

  @doc """
  Verify a session token and return the principal_id if valid.

  The HMAC is checked over the raw transported payload bytes BEFORE the
  payload is deserialized, so a forged/garbage token can never drive
  `binary_to_term` on attacker-controlled bytes.

  Oversized and empty binaries are rejected before any Base64 decode or
  HMAC work (`@max_token_bytes` = 4096).
  """
  @spec verify(binary()) :: {:ok, String.t()} | {:error, term()}
  def verify(token)
      when is_binary(token) and byte_size(token) > 0 and byte_size(token) <= @max_token_bytes do
    with {:ok, signature, payload_bytes} <- split_token(token),
         :ok <- verify_mac(payload_bytes, signature),
         {:ok, payload} <- safe_decode_payload(payload_bytes),
         :ok <- check_version(payload),
         :ok <- check_expiry(payload),
         :ok <- check_session(payload) do
      {:ok, payload.pid}
    end
  end

  def verify(token) when is_binary(token), do: {:error, :invalid_token}
  def verify(_), do: {:error, :invalid_token}

  @doc """
  Check if a value is a valid session token (without full verification).
  """
  @spec token?(term()) :: boolean()
  def token?(token) when is_binary(token) and byte_size(token) > 20, do: true
  def token?(_), do: false

  # --- Private ---

  # HMAC-SHA256 is always 32 bytes; the wire format is `sig <> payload_bytes`.
  @sig_size 32

  # Split the token into signature + raw payload bytes using pure binary
  # slicing — NO term deserialization here, so this runs safely on
  # untrusted input before any authentication.
  defp split_token(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, <<signature::binary-size(@sig_size), payload_bytes::binary>>}
      when byte_size(payload_bytes) > 0 ->
        {:ok, signature, payload_bytes}

      {:ok, _too_short} ->
        {:error, :malformed_token}

      :error ->
        {:error, :invalid_base64}
    end
  end

  defp verify_mac(payload_bytes, signature) do
    if secure_compare(mac(payload_bytes), signature) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  # Only called AFTER the HMAC has been verified — at this point the bytes
  # are known to have been produced by us. `[:safe]` is belt-and-suspenders.
  defp safe_decode_payload(payload_bytes) do
    case :erlang.binary_to_term(payload_bytes, [:safe]) do
      %{v: _, pid: pid, sid: _, iat: _, exp: _} = payload when is_binary(pid) ->
        {:ok, payload}

      _ ->
        {:error, :malformed_token}
    end
  rescue
    _ -> {:error, :invalid_binary}
  end

  defp check_version(%{v: @token_version, purpose: :human_session} = payload) do
    if map_size(payload) == 7 and
         valid_general_claims?(
           payload.pid,
           payload.sid,
           payload.iat,
           payload.exp,
           payload.scopes
         ),
       do: :ok,
       else: {:error, :malformed_token}
  end

  defp check_version(%{v: 1}), do: {:error, :legacy_session_token}
  defp check_version(%{v: v}), do: {:error, {:unsupported_version, v}}

  defp check_expiry(%{exp: exp}) do
    now = DateTime.to_unix(DateTime.utc_now())

    if now < exp do
      :ok
    else
      {:error, :token_expired}
    end
  end

  @doc "Revoke one session immediately by its opaque session id."
  @spec revoke_session(String.t()) :: {:error, :session_mutation_unauthorized}
  def revoke_session(_session_id), do: {:error, :session_mutation_unauthorized}

  @doc "Authenticate and revoke the exact session represented by a bearer token."
  @spec revoke(binary()) :: :ok | {:error, term()}
  def revoke(token) when is_binary(token),
    do: Arbor.Security.SessionRegistry.revoke_token(token)

  def revoke(_), do: {:error, :invalid_token}

  @doc false
  def registry_revoke_claim(token)
      when is_binary(token) and byte_size(token) > 0 and byte_size(token) <= @max_token_bytes do
    if Arbor.Security.SessionRegistry.owner_process?() do
      with {:ok, signature, bytes} <- split_token(token),
           :ok <- verify_mac(bytes, signature),
           {:ok, payload} <- safe_decode_payload(bytes),
           :ok <- validate_revoke_payload(payload) do
        {:ok, payload.sid}
      else
        _ -> {:error, :invalid_token}
      end
    else
      {:error, :session_mutation_unauthorized}
    end
  end

  def registry_revoke_claim(_), do: {:error, :invalid_token}

  defp validate_revoke_payload(%{purpose: :human_session} = payload),
    do: check_version(payload)

  defp validate_revoke_payload(
         %{
           v: 2,
           purpose: :conversation,
           target: target,
           pid: principal,
           sid: sid,
           iat: issued,
           exp: expires
         } = payload
       ) do
    if map_size(payload) == 7 and conversation_id?(principal, "human_") and
         conversation_target?(target) and valid_session_id?(sid) and is_integer(issued) and
         is_integer(expires) and expires - issued == 90,
       do: :ok,
       else: {:error, :invalid_token}
  end

  defp validate_revoke_payload(_), do: {:error, :invalid_token}

  defp check_session(%{sid: sid, pid: principal}) do
    if Arbor.Security.SessionRegistry.active?(sid, principal),
      do: :ok,
      else: {:error, :session_revoked}
  end

  defp validate_generate_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:ttl, :max_expires_at, :session_id])) and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) and
         Keyword.get(opts, :ttl, @default_ttl_seconds) in 1..@default_ttl_seconds,
       do: :ok,
       else: {:error, :invalid_options}
  end

  defp validate_generate_options(_), do: {:error, :invalid_options}

  defp validate_session_id(id) when is_binary(id) do
    if byte_size(id) == 32 and String.valid?(id) and Regex.match?(~r/\A[0-9a-f]{32}\z/, id),
      do: :ok,
      else: {:error, :invalid_session_id}
  end

  defp validate_session_id(_), do: {:error, :invalid_session_id}

  defp valid_general_claims?(principal, sid, issued, expires, scopes) do
    is_binary(principal) and principal != "" and valid_session_id?(sid) and
      is_integer(issued) and is_integer(expires) and expires > issued and
      expires - issued <= @default_ttl_seconds and scopes == default_scopes()
  end

  defp valid_session_id?(id), do: validate_session_id(id) == :ok

  defp default_scopes do
    @default_scopes
  end

  defp scope_matches?(prefix, resource, _action) when is_binary(prefix) do
    Arbor.Contracts.Security.CapabilityUri.prefix_match?(prefix, resource)
  rescue
    _ -> false
  end

  defp scope_matches?(_, _, _), do: false

  defp approval_resource?(resource) do
    Arbor.Contracts.Security.CapabilityUri.prefix_match?("arbor://approval", resource)
  rescue
    _ -> false
  end

  defp mac(bytes) when is_binary(bytes) do
    :crypto.mac(:hmac, :sha256, token_secret(), bytes)
  end

  defp token_secret do
    case configuration_status() do
      :ok -> Application.fetch_env!(:arbor_security, :session_token_secret)
      {:error, reason} -> raise "session token configuration rejected: #{reason}"
    end
  end

  # Constant-time comparison to prevent timing attacks
  defp secure_compare(a, b) when byte_size(a) == byte_size(b) do
    :crypto.hash_equals(a, b)
  end

  defp secure_compare(_, _), do: false

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
