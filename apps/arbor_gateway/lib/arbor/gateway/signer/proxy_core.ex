defmodule Arbor.Gateway.Signer.ProxyCore do
  @moduledoc """
  Pure functional core for the MCP signing proxy.

  Handles the parts of the proxy that have no IO: parsing key files,
  computing canonical signed payloads, building the wire envelope, and
  formatting JSON-RPC error responses. The IO loop, the HTTP forwarding,
  and the stdin/stdout reading live in `Arbor.Gateway.Signer.Proxy`.

  All functions are pure and can be tested without spawning processes,
  hitting the network, or touching the filesystem.

  ## CRC Pipeline

      key_file_contents
      |> ProxyCore.parse_key_file()
      |> ProxyCore.with_signed_envelope("POST", "/mcp", body)
      |> ProxyCore.encode_authorization_header()
  """

  alias Arbor.Contracts.Security.SignedRequest

  # ===========================================================================
  # Construct: parse the key file format
  # ===========================================================================

  @typedoc """
  Parsed contents of a `.arbor.key` file.

  - `agent_id`: the cluster-registered agent ID
  - `private_key`: the raw 32-byte Ed25519 private key (decoded from base64)
  """
  @type key_material :: %{
          agent_id: String.t(),
          private_key: binary()
        }

  @doc """
  Parse the contents of a `.arbor.key` file.

  Delegates to `Arbor.Security.KeyFile.parse/1` — the canonical home for
  this parsing logic. Kept here as a backward-compat shim because external
  callers (and `mix arbor.signer`) use this name. New callers should
  reference `Arbor.Security.KeyFile.parse/1` directly.
  """
  @spec parse_key_file(String.t()) :: {:ok, key_material()} | {:error, atom() | tuple()}
  defdelegate parse_key_file(contents), to: Arbor.Security.KeyFile, as: :parse

  # ===========================================================================
  # Reduce: compute canonical bytes the SignedRequestAuth plug expects
  # ===========================================================================

  @doc """
  Build the canonical signing payload for a request.

  Mirrors the format reconstructed server-side by
  `Arbor.Gateway.SignedRequestAuth.bind_payload/3`. The byte layout is:

      method <> "\\n" <> request_path <> "\\n" <> body

  Both sides must produce identical bytes for signature verification to
  succeed. Any drift here breaks every signed request.
  """
  @spec canonical_payload(String.t(), String.t(), binary()) :: binary()
  def canonical_payload(method, request_path, body)
      when is_binary(method) and is_binary(request_path) and is_binary(body) do
    IO.iodata_to_binary([method, "\n", request_path, "\n", body])
  end

  # ===========================================================================
  # Reduce: build a SignedRequest envelope (signing happens here)
  # ===========================================================================

  @doc """
  Sign a request and return the wire envelope plus the canonical payload.

  Performs the actual Ed25519 signing using the agent's private key.
  This is "pure" in the functional-core sense even though it calls
  `:crypto.sign/4` internally — the function has no IO, no process state,
  and is deterministic given the same `(timestamp, nonce, payload)` triple.

  In practice we accept an injectable `now_fun` and `nonce_fun` so tests
  can lock down both fields and assert against a fixed expected envelope.
  """
  @spec sign_request(
          key_material(),
          String.t(),
          String.t(),
          binary(),
          keyword()
        ) :: {:ok, SignedRequest.t()} | {:error, term()}
  def sign_request(key_material, method, request_path, body, _opts \\ []) do
    payload = canonical_payload(method, request_path, body)
    SignedRequest.sign(payload, key_material.agent_id, key_material.private_key)
  end

  # ===========================================================================
  # Convert: serialize the envelope for the Authorization header
  # ===========================================================================

  @doc """
  Encode a `SignedRequest` struct as the wire envelope expected by
  `Arbor.Gateway.SignedRequestAuth`.

  Returns the base64-encoded JSON object ready to be slotted into:

      Authorization: Signature <returned-string>

  The payload field is intentionally NOT included in the envelope — the
  server reconstructs it from the actual request bytes. Including it
  would let an attacker pre-compute a payload mismatch attack.
  """
  @spec encode_envelope(SignedRequest.t()) :: String.t()
  def encode_envelope(%SignedRequest{} = signed) do
    %{
      "agent_id" => signed.agent_id,
      "timestamp" => DateTime.to_iso8601(signed.timestamp),
      "nonce" => Base.encode64(signed.nonce),
      "signature" => Base.encode64(signed.signature)
    }
    |> Jason.encode!()
    |> Base.encode64(padding: false)
  end

  @doc """
  Build the full `Authorization` header value (scheme + encoded envelope).
  """
  @spec authorization_header_value(SignedRequest.t()) :: String.t()
  def authorization_header_value(%SignedRequest{} = signed) do
    "Signature " <> encode_envelope(signed)
  end

  # ===========================================================================
  # Convert: JSON-RPC error response formatting
  # ===========================================================================

  @doc """
  Build a JSON-RPC error response object.

  Used when the proxy itself fails (signing error, upstream HTTP error,
  malformed input) and needs to return an error to the MCP client without
  ever reaching the upstream gateway. The `id` is taken from the original
  request when known, or `nil` for parse errors.

  Standard JSON-RPC 2.0 error codes:
  - `-32700` parse error
  - `-32600` invalid request
  - `-32603` internal error
  """
  @spec jsonrpc_error_response(integer() | String.t() | nil, integer(), String.t(), map() | nil) ::
          map()
  def jsonrpc_error_response(id, code, message, data \\ nil) do
    error = %{"code" => code, "message" => message}
    error = if data, do: Map.put(error, "data", data), else: error

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => error
    }
  end

  @doc """
  Extract the JSON-RPC `id` from a parsed request map, returning `nil`
  if absent or malformed. Used so error responses correlate with the
  request they're failing on.
  """
  @spec extract_id(map() | nil) :: integer() | String.t() | nil
  def extract_id(nil), do: nil
  def extract_id(%{"id" => id}) when is_integer(id) or is_binary(id), do: id
  def extract_id(_), do: nil
end
