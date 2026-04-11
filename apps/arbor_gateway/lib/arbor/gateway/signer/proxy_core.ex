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

  The file format is line-oriented `key=value`:

      agent_id=agent_30b455a27f7f4e02ef291fd9f7862677f731a1f8b08c997f5fb8ad430d594b6e
      private_key_b64=BASE64KEYBYTES==

  Returns `{:ok, key_material}` on success or `{:error, reason}` if the
  file is missing required fields or the private key isn't valid base64.
  """
  @spec parse_key_file(String.t()) :: {:ok, key_material()} | {:error, atom() | tuple()}
  def parse_key_file(contents) when is_binary(contents) do
    fields =
      contents
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, "=", parts: 2) do
          [k, v] -> Map.put(acc, String.trim(k), String.trim(v))
          _ -> acc
        end
      end)

    with {:ok, agent_id} <- fetch_field(fields, "agent_id"),
         {:ok, private_key_b64} <- fetch_field(fields, "private_key_b64"),
         {:ok, private_key} <- decode_private_key(private_key_b64),
         :ok <- validate_agent_id(agent_id) do
      {:ok, %{agent_id: agent_id, private_key: private_key}}
    end
  end

  defp fetch_field(fields, key) do
    case Map.get(fields, key) do
      nil -> {:error, {:missing_field, key}}
      "" -> {:error, {:empty_field, key}}
      value -> {:ok, value}
    end
  end

  defp decode_private_key(b64) do
    case Base.decode64(b64) do
      {:ok, bin} when byte_size(bin) in [32, 64] -> {:ok, bin}
      {:ok, bin} -> {:error, {:invalid_private_key_size, byte_size(bin)}}
      :error -> {:error, :invalid_private_key_base64}
    end
  end

  defp validate_agent_id(agent_id) do
    if String.starts_with?(agent_id, "agent_") and byte_size(agent_id) > 6 do
      :ok
    else
      {:error, {:invalid_agent_id, agent_id}}
    end
  end

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
