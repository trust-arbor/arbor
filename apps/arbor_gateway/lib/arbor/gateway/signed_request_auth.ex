defmodule Arbor.Gateway.SignedRequestAuth do
  @moduledoc """
  Per-request signature authentication plug for the Gateway.

  External agents (Claude Code, Codex, future tools) authenticate by signing
  each HTTP request with their Ed25519 private key. The agent's public key was
  registered server-side via the dashboard "External Agents" UI; the private
  key was returned to the human operator exactly once and pasted into the
  external tool's configuration.

  ## Wire Format

  The client sends an `Authorization: Signature <base64>` header where
  `<base64>` is the base64-encoded JSON envelope:

      {
        "agent_id":  "agent_a1b2c3...",
        "timestamp": "2026-04-11T12:30:00Z",
        "nonce":     "<base64 16-byte random>",
        "signature": "<base64 Ed25519 signature>"
      }

  The signed payload (the bytes the client actually fed to Ed25519) is the
  canonical request fingerprint:

      payload = method <> "\\n" <> request_path <> "\\n" <> body

  Method and path are not transmitted in the header — the server reconstructs
  them from the conn. Body is read from the request stream and cached in
  `conn.assigns[:raw_body]` so downstream plugs (ExMCP.HttpPlug) can pick it up
  via `read_or_cached_body/1` instead of trying to re-read the consumed stream.

  ## Behaviour

  - **Header present, signature valid** → assigns `:agent_id` and
    `:signed_request_authenticated`, body is cached for downstream
  - **Header present, signature invalid** → pass through (lets API key
    auth fall back); body is still cached if it was read
  - **Header absent** → pass through without touching the body

  This is intentionally non-destructive so the existing JWT and API key auth
  flows still work for human operators using the dashboard.

  ## Replay protection

  `Arbor.Security.verify_request/1` enforces:
  - Timestamp freshness (configurable drift window)
  - Public key lookup against the live `IdentityRegistry`
  - Ed25519 signature verification
  - Nonce uniqueness via the `NonceCache`

  A captured signature is therefore bound to method+path+body+timestamp+nonce
  and is unusable after the nonce has been consumed.
  """

  import Plug.Conn

  alias Arbor.Contracts.Security.SignedRequest

  require Logger

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case extract_signature_header(conn) do
      {:ok, encoded} ->
        attempt_signature_auth(conn, encoded)

      :no_signature ->
        conn
    end
  end

  # --- Pipeline steps ---

  defp attempt_signature_auth(conn, encoded) do
    with {:ok, partial_signed_request} <- decode_signed_request(encoded),
         {:ok, body, conn} <- read_and_cache_body(conn),
         {:ok, signed_request} <- bind_payload(partial_signed_request, conn, body),
         {:ok, agent_id} <- Arbor.Security.verify_request(signed_request) do
      Logger.debug("[SignedRequestAuth] Authenticated agent #{agent_id}")

      # Stash the verified agent_id in the process dictionary so the
      # downstream MCP tool handler can read it without us having to
      # patch ExMCP.MessageProcessor to thread Plug.Conn assigns through.
      # Plug pipelines run synchronously in the request process, so this
      # is safe within a single request lifecycle.
      Process.put(:arbor_authenticated_agent_id, agent_id)

      conn
      |> assign(:agent_id, agent_id)
      |> assign(:signed_request_authenticated, true)
    else
      {:error, reason} ->
        Logger.debug("[SignedRequestAuth] Verification failed: #{inspect(reason)}")
        # Non-destructive passthrough — let downstream auth try.
        # Body, if read, is already in assigns[:raw_body] for ExMCP.
        conn
    end
  end

  # --- Header extraction ---

  defp extract_signature_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Signature " <> rest] ->
        encoded = String.trim(rest)
        if encoded == "", do: :no_signature, else: {:ok, encoded}

      _ ->
        :no_signature
    end
  end

  # --- Decode the wire envelope into a SignedRequest struct ---

  defp decode_signed_request(encoded) do
    with {:ok, json} <- Base.decode64(encoded, padding: false) |> ok_or(:invalid_base64),
         {:ok, map} <- Jason.decode(json) |> ok_or(:invalid_json),
         {:ok, agent_id} <- fetch_string(map, "agent_id"),
         {:ok, ts_string} <- fetch_string(map, "timestamp"),
         {:ok, nonce_b64} <- fetch_string(map, "nonce"),
         {:ok, sig_b64} <- fetch_string(map, "signature"),
         {:ok, timestamp, _offset} <- DateTime.from_iso8601(ts_string),
         {:ok, nonce} <- Base.decode64(nonce_b64) |> ok_or(:invalid_nonce_encoding),
         {:ok, signature} <- Base.decode64(sig_b64) |> ok_or(:invalid_signature_encoding) do
      # Payload is reconstructed server-side from the actual request,
      # not transmitted in the envelope. We pass an empty placeholder here;
      # `verify_payload_binds_request/3` fills it in before crypto verification.
      SignedRequest.new(
        payload: <<0>>,
        agent_id: agent_id,
        timestamp: timestamp,
        nonce: nonce,
        signature: signature
      )
    end
  end

  defp ok_or({:ok, _} = ok, _err), do: ok
  defp ok_or(:error, err), do: {:error, err}
  defp ok_or({:error, _}, err), do: {:error, err}

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_or_invalid_field, key}}
    end
  end

  # --- Body read with caching ---

  defp read_and_cache_body(conn) do
    case read_body(conn) do
      {:ok, body, conn} ->
        {:ok, body, assign(conn, :raw_body, body)}

      {:more, _partial, _conn} ->
        # Body too large to read in one shot. We don't try to support
        # streamed bodies for signed requests — sign once, send once.
        {:error, :body_too_large}

      {:error, reason} ->
        {:error, {:read_body_failed, reason}}
    end
  end

  # --- Payload binding ---

  # The client signs `method <> "\n" <> request_path <> "\n" <> body`. We
  # rebuild that exact bytestring from the conn and the cached body, then
  # replace the placeholder payload in the SignedRequest with the rebuilt one.
  # `Arbor.Security.verify_request/1` will recompute the canonical signing
  # payload over this corrected struct and verify the Ed25519 signature.
  defp bind_payload(%SignedRequest{} = partial, conn, body) do
    canonical = IO.iodata_to_binary([conn.method, "\n", conn.request_path, "\n", body])
    {:ok, %{partial | payload: canonical}}
  end
end
