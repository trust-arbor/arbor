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

      # Generate during OIDC callback
      {:ok, token} = SessionToken.generate("human_abc123")

      # Verify in authorize calls
      {:ok, principal_id} = SessionToken.verify(token)

      # Pass to Security.authorize
      Security.authorize(principal_id, resource, action, session_token: token)
  """

  require Logger

  @default_ttl_seconds 86_400
  @token_version 1
  # Bound before Base64/HMAC work. Comfortably exceeds generated tokens.
  @max_token_bytes 4096

  @doc """
  Generate a signed session token for a human principal.

  A trusted caller may pass `:max_expires_at` (Unix seconds) to cap the token
  at the expiry of the authentication that established the session. Invalid
  or elapsed bounds are rejected. Omitting it preserves the normal TTL.
  """
  @spec generate(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def generate(principal_id, opts \\ []) when is_binary(principal_id) do
    ttl = Keyword.get(opts, :ttl, @default_ttl_seconds)
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, ttl, :second)
    session_id = Keyword.get(opts, :session_id, generate_session_id())

    with {:ok, expires_at} <- cap_expiry(expires_at, now, opts) do
      payload = %{
        v: @token_version,
        pid: principal_id,
        sid: session_id,
        iat: DateTime.to_unix(now),
        exp: DateTime.to_unix(expires_at)
      }

      # Sign the EXACT bytes that get transported — never a re-serialization.
      payload_bytes = :erlang.term_to_binary(payload)
      signature = mac(payload_bytes)

      token = Base.url_encode64(signature <> payload_bytes, padding: false)

      {:ok, token}
    end
  end

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
  def generate_conversation(principal, target) do
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

      bytes = :erlang.term_to_binary(payload)
      {:ok, Base.url_encode64(mac(bytes) <> bytes, padding: false)}
    else
      {:error, :invalid_token_scope}
    end
  end

  @doc """
  Verify authentication for the actual resource and action.

  Legacy v1 login tokens retain their existing behavior. Version 2 conversation
  tokens can authenticate only `:chat` on their exact target; generic `verify/1`
  deliberately rejects them, so other token consumers cannot widen their scope.
  """
  def verify_for(token, resource, action)
      when is_binary(token) and byte_size(token) > 0 and byte_size(token) <= @max_token_bytes do
    with {:ok, signature, bytes} <- split_token(token),
         :ok <- verify_mac(bytes, signature),
         {:ok, payload} <- safe_decode_payload(bytes),
         :ok <- check_scope(payload, resource, action),
         :ok <- check_expiry(payload) do
      {:ok, payload.pid}
    end
  end

  def verify_for(_, _, _), do: {:error, :invalid_token}

  defp check_scope(%{v: @token_version}, _, _), do: :ok

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
         :ok <- check_expiry(payload) do
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

  defp check_version(%{v: @token_version}), do: :ok
  defp check_version(%{v: v}), do: {:error, {:unsupported_version, v}}

  defp check_expiry(%{exp: exp}) do
    now = DateTime.to_unix(DateTime.utc_now())

    if now < exp do
      :ok
    else
      {:error, :token_expired}
    end
  end

  defp mac(bytes) when is_binary(bytes) do
    :crypto.mac(:hmac, :sha256, token_secret(), bytes)
  end

  defp token_secret do
    Application.get_env(:arbor_security, :session_token_secret) ||
      raise "session_token_secret not configured — set config :arbor_security, :session_token_secret"
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
