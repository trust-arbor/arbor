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

  @doc """
  Generate a signed session token for a human principal.
  """
  @spec generate(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def generate(principal_id, opts \\ []) when is_binary(principal_id) do
    ttl = Keyword.get(opts, :ttl, @default_ttl_seconds)
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, ttl, :second)
    session_id = Keyword.get(opts, :session_id, generate_session_id())

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

  @doc """
  Verify a session token and return the principal_id if valid.

  The HMAC is checked over the raw transported payload bytes BEFORE the
  payload is deserialized, so a forged/garbage token can never drive
  `binary_to_term` on attacker-controlled bytes.
  """
  @spec verify(binary()) :: {:ok, String.t()} | {:error, term()}
  def verify(token) when is_binary(token) do
    with {:ok, signature, payload_bytes} <- split_token(token),
         :ok <- verify_mac(payload_bytes, signature),
         {:ok, payload} <- safe_decode_payload(payload_bytes),
         :ok <- check_version(payload),
         :ok <- check_expiry(payload) do
      {:ok, payload.pid}
    end
  end

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
