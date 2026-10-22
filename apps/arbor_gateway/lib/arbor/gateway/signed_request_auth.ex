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

  ## Agent-lifecycle authority

  With `agent_lifecycle_authority: true` (set by the parent router for the
  chat create and start routes) a `human_` signer is verified by
  `Arbor.Security.verify_request_and_open_agent_lifecycle_authority/2`
  instead, which runs the same checks and, in the same step, opens an
  `:agent_lifecycle` authority from the human's server-held key, bound to the
  request process. It is stored in `conn.private` (read it with
  `agent_lifecycle_authority/1`) and closed before the response is sent. If
  it cannot be opened, the request is not authenticated.
  """

  import Plug.Conn

  alias Arbor.Contracts.Security.SignedRequest

  require Logger

  @behaviour Plug

  # Match ExMCP.HttpPlug's 1 MiB body cap so a signed request cannot buffer
  # Plug's 8 MB default ahead of the MCP transport limit.
  @max_body_bytes 1_048_576

  @doc "Maximum signed-request body size, in bytes (1 MiB)."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: @max_body_bytes

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    case extract_signature_header(conn) do
      {:ok, encoded} ->
        attempt_signature_auth(conn, encoded, agent_lifecycle_authority?(opts))

      :no_signature ->
        conn
    end
  end

  @doc """
  The agent-lifecycle authority this plug opened for the current request, or
  `nil`.

  Set only for requests the caller marked with
  `agent_lifecycle_authority: true` whose verified signer is a `human_`
  principal. The authority is bound to the request process and closed before
  the response is sent; the route that consumes it also closes it.
  """
  @spec agent_lifecycle_authority(Plug.Conn.t()) :: term() | nil
  def agent_lifecycle_authority(%Plug.Conn{private: private}),
    do: Map.get(private, :arbor_agent_lifecycle_authority)

  @doc "Close the request's agent-lifecycle authority, if any. Idempotent."
  @spec close_agent_lifecycle_authority(Plug.Conn.t()) :: :ok
  def close_agent_lifecycle_authority(conn) do
    case agent_lifecycle_authority(conn) do
      nil -> :ok
      authority -> close_authority(authority)
    end
  end

  # --- Pipeline steps ---

  defp agent_lifecycle_authority?(opts) when is_list(opts),
    do: Keyword.get(opts, :agent_lifecycle_authority, false) == true

  defp agent_lifecycle_authority?(_opts), do: false

  defp attempt_signature_auth(conn, encoded, lifecycle_authority?) do
    with {:ok, partial_signed_request} <- decode_signed_request(encoded),
         {:ok, body, conn} <- read_and_cache_body(conn),
         {:ok, signed_request} <- bind_payload(partial_signed_request, conn, body),
         {:ok, agent_id, conn} <- verify(conn, signed_request, body, lifecycle_authority?) do
      Logger.debug("[SignedRequestAuth] Authenticated agent #{agent_id}")

      # Stash the verified agent_id AND the signed_request struct in the
      # process dictionary so the downstream MCP tool handler can read both
      # without us having to patch ExMCP.MessageProcessor to thread
      # Plug.Conn assigns through. Plug pipelines run synchronously in the
      # request process, so this is safe within a single request lifecycle.
      #
      # H1: pre-fix, only agent_id was stashed — Arbor.Actions.authorize_and_execute
      # then ran with no :signed_request in its context, so the action-layer
      # `verify_identity: true` config produced :missing_signed_request even
      # though the HTTP request had been authenticated upstream. The fix
      # forwards the bound signed_request struct so action auth can verify
      # against the same proof the gateway already verified.
      Process.put(:arbor_authenticated_agent_id, agent_id)
      Process.put(:arbor_authenticated_signed_request, signed_request)

      conn
      |> assign(:agent_id, agent_id)
      |> assign(:signed_request, signed_request)
      |> assign(:signed_request_authenticated, true)
    else
      {:error, {:body_too_large, conn}} ->
        reject_too_large(conn)

      {:error, reason} ->
        Logger.debug("[SignedRequestAuth] Verification failed: #{inspect(reason)}")
        # Non-destructive passthrough — let downstream auth try.
        # Body, if read, is already in assigns[:raw_body] for ExMCP.
        #
        # Record the reason. Without it the API-key plug runs next, finds no
        # Bearer/x-api-key header (this request carried `Authorization:
        # Signature ...`), and answers "Missing API key" — which sends the
        # operator hunting for a credential they already supplied correctly.
        assign(conn, :signed_request_auth_error, reason)
    end
  end

  # A human's signed request to an agent-lifecycle route is verified by the
  # one-step operation that also opens their `:agent_lifecycle` authority:
  # verification consumes the nonce, so the authority could not be opened from
  # this request afterwards (decision 2026-10-08 D2). Any other signer, and
  # every other route, uses the plain verifier and gets no authority; the
  # lifecycle facade then refuses the mutation for lack of one.
  defp verify(conn, %SignedRequest{agent_id: "human_" <> _} = signed_request, body, true) do
    case Arbor.Security.verify_request_and_open_agent_lifecycle_authority(
           signed_request,
           request_payload(conn, body)
         ) do
      {:ok, agent_id, authority} ->
        conn =
          conn
          |> put_private(:arbor_agent_lifecycle_authority, authority)
          |> register_before_send(fn conn ->
            close_authority(authority)
            conn
          end)

        {:ok, agent_id, conn}

      {:error, _reason} = error ->
        error
    end
  end

  defp verify(conn, signed_request, _body, _lifecycle_authority?) do
    case Arbor.Security.verify_request(signed_request) do
      {:ok, agent_id} -> {:ok, agent_id, conn}
      {:error, _reason} = error -> error
    end
  end

  defp close_authority(authority) do
    _ = Arbor.Security.close_signing_authority(authority)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
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
    case read_body(conn, length: @max_body_bytes) do
      {:ok, body, conn} ->
        {:ok, body, assign(conn, :raw_body, body)}

      {:more, _partial, conn} ->
        # Stop at the first oversize chunk. Do not keep reading — that would
        # buffer past the 1 MiB cap that ExMCP already enforces.
        {:error, {:body_too_large, conn}}

      {:error, reason} ->
        {:error, {:read_body_failed, reason}}
    end
  end

  defp reject_too_large(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(413, Jason.encode!(%{error: "Payload Too Large"}))
    |> halt()
  end

  # --- Payload binding ---

  # The client signs `method <> "\n" <> request_path <> "\n" <> body`. We
  # rebuild that exact bytestring from the conn and the cached body, then
  # replace the placeholder payload in the SignedRequest with the rebuilt one.
  # `Arbor.Security.verify_request/1` will recompute the canonical signing
  # payload over this corrected struct and verify the Ed25519 signature.
  defp bind_payload(%SignedRequest{} = partial, conn, body) do
    {:ok, %{partial | payload: request_payload(conn, body)}}
  end

  # The exact request this conn will serve. The lifecycle authority is opened
  # only for a signature over these bytes.
  defp request_payload(conn, body),
    do: IO.iodata_to_binary([conn.method, "\n", conn.request_path, "\n", body])
end
