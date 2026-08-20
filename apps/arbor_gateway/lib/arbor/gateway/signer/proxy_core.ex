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

  @typedoc "Validated inputs for one transparent HTTP session recovery attempt."
  @type recovery_plan :: %{
          initialize_body: binary(),
          initialized_body: binary(),
          expected_protocol: binary()
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

  # ===========================================================================
  # Convert: Streamable HTTP session headers for the stdio proxy
  # ===========================================================================

  @session_header "mcp-session-id"
  @protocol_header "mcp-protocol-version"
  @max_invalidation_body_bytes 16_384

  @doc """
  Read a server-issued `mcp-session-id` from HTTP response headers.

  Header names are matched case-insensitively and may arrive as strings or
  `:httpc` charlists.
  """
  @spec session_id_from_headers([{term(), term()}]) :: String.t() | nil
  def session_id_from_headers(headers) when is_list(headers) do
    fetch_header(headers, @session_header)
  end

  @doc """
  Read `mcp-protocol-version` from HTTP response headers.
  """
  @spec protocol_version_from_headers([{term(), term()}]) :: String.t() | nil
  def protocol_version_from_headers(headers) when is_list(headers) do
    fetch_header(headers, @protocol_header)
  end

  @doc """
  Read `params.protocolVersion` from an `initialize` JSON-RPC body.
  """
  @spec protocol_version_from_initialize_body(binary()) :: String.t() | nil
  def protocol_version_from_initialize_body(body) when is_binary(body) do
    case parse_initialize_request(body) do
      {:initialize, version} -> version
      :other -> nil
    end
  end

  @doc """
  Prepare the HTTP session before forwarding a JSON-RPC request.

  Every `initialize` begins a fresh HTTP session, even when the stdio proxy
  process outlives an upstream server. The prior session ID is discarded and
  the requested protocol replaces the prior value, including with `nil` when
  `params.protocolVersion` is absent or invalid.
  """
  @spec prepare_http_session(map(), binary()) :: map()
  def prepare_http_session(session, body) when is_map(session) and is_binary(body) do
    case parse_initialize_request(body) do
      {:initialize, version} ->
        session
        |> Map.put(:session_id, nil)
        |> Map.put(:protocol_version, version)
        |> Map.put(:cached_initialize_body, nil)
        |> Map.put(:cached_initialized_body, nil)

      :other ->
        session
    end
  end

  @doc """
  Adopt any session/protocol headers from an upstream HTTP response.

  Missing headers leave the current values in place so a 202 notification
  cannot wipe a session issued on `initialize`.
  """
  @spec adopt_http_session(map(), [{term(), term()}] | nil) :: map()
  def adopt_http_session(session, headers) when is_map(session) do
    session
    |> maybe_put(:session_id, session_id_from_headers(List.wrap(headers)))
    |> maybe_put(:protocol_version, protocol_version_from_headers(List.wrap(headers)))
  end

  @doc """
  Adopt session state from a successful upstream HTTP response.

  Response headers retain their existing behavior. For an `initialize`
  request, `result.protocolVersion` in the JSON response then becomes the
  negotiated protocol, including when the HTTP response omits the protocol
  header.
  """
  @spec adopt_http_session(map(), [{term(), term()}] | nil, binary(), binary() | nil) :: map()
  def adopt_http_session(session, headers, request_body, response_body)
      when is_map(session) and is_binary(request_body) do
    adopted = adopt_http_session(session, headers)

    case parse_initialize_request(request_body) do
      {:initialize, _requested} ->
        case protocol_version_from_initialize_response(response_body) do
          version when is_binary(version) ->
            adopted
            |> Map.put(:protocol_version, version)
            |> Map.put(:cached_initialize_body, request_body)
            |> Map.put(:cached_initialized_body, nil)

          nil ->
            adopted
        end

      :other ->
        adopted
    end
  end

  @doc "Remember an acknowledged `notifications/initialized` request for recovery replay."
  @spec remember_successful_initialized(map(), binary()) :: map()
  def remember_successful_initialized(session, request_body)
      when is_map(session) and is_binary(request_body) do
    maybe_cache_initialized(session, request_body)
  end

  @doc """
  Build one recovery plan from a complete, compatible cached MCP lifecycle.

  The cached initialize request and a successfully forwarded
  `notifications/initialized` request must both be present. The returned
  session has no HTTP session ID and no cached lifecycle so replay responses
  must repopulate both before the original request can be retried. A fresh
  initialize response must reproduce the protocol originally negotiated with
  the stdio client, even when that differs from the client's requested version.
  """
  @spec begin_http_session_recovery(map()) ::
          {:ok, map(), recovery_plan()}
          | {:error, :incomplete_cached_lifecycle | tuple()}
  def begin_http_session_recovery(session) when is_map(session) do
    initialize_body = Map.get(session, :cached_initialize_body)
    initialized_body = Map.get(session, :cached_initialized_body)
    expected_protocol = Map.get(session, :protocol_version)

    case {initialize_body, initialized_body, expected_protocol} do
      {initialize_body, initialized_body, expected_protocol}
      when is_binary(initialize_body) and is_binary(initialized_body) and
             is_binary(expected_protocol) and expected_protocol != "" ->
        build_recovery_plan(
          session,
          initialize_body,
          initialized_body,
          expected_protocol
        )

      _other ->
        {:error, :incomplete_cached_lifecycle}
    end
  end

  @doc """
  Admit one upstream response while replaying the cached lifecycle.

  Initialize replay requires HTTP 200, a valid initialize result, a new
  server-issued session ID, and the protocol already negotiated with the stdio
  client. Initialized replay requires the normal empty HTTP 202/204 response
  and preserves the same session/protocol invariants.
  """
  @spec apply_http_session_recovery_response(
          map(),
          recovery_plan(),
          :initialize | :initialized,
          integer(),
          [{term(), term()}] | nil,
          binary() | nil
        ) :: {:ok, map()} | {:error, term()}
  def apply_http_session_recovery_response(
        session,
        plan,
        :initialize,
        200,
        headers,
        response_body
      )
      when is_map(session) and is_map(plan) and is_binary(response_body) do
    next =
      adopt_http_session(
        session,
        headers,
        plan.initialize_body,
        response_body
      )

    with true <- Map.get(next, :cached_initialize_body) == plan.initialize_body,
         :ok <- validate_recovery_session(next, plan.expected_protocol) do
      {:ok, next}
    else
      false -> {:error, :invalid_initialize_response}
      {:error, _reason} = error -> error
    end
  end

  def apply_http_session_recovery_response(
        session,
        plan,
        :initialized,
        status,
        headers,
        response_body
      )
      when is_map(session) and is_map(plan) and status in [202, 204] and
             response_body in ["", nil] do
    next =
      adopt_http_session(
        session,
        headers,
        plan.initialized_body,
        response_body
      )
      |> remember_successful_initialized(plan.initialized_body)

    with true <- Map.get(next, :cached_initialized_body) == plan.initialized_body,
         :ok <- validate_recovery_session(next, plan.expected_protocol) do
      {:ok, next}
    else
      false -> {:error, :invalid_initialized_response}
      {:error, _reason} = error -> error
    end
  end

  def apply_http_session_recovery_response(
        _session,
        _plan,
        stage,
        status,
        _headers,
        _response_body
      ),
      do: {:error, {:unexpected_recovery_response, stage, status}}

  @doc "Clear transport state after a failed recovery while retaining lifecycle evidence."
  @spec clear_http_session(map()) :: map()
  def clear_http_session(session) when is_map(session) do
    session
    |> Map.put(:session_id, nil)
    |> Map.put(:protocol_version, nil)
  end

  @doc """
  Return whether an upstream response proves the held HTTP session is stale.

  Classification is deliberately narrow and bounded. It applies only to a
  non-initialize request carrying an existing session, and recognizes the two
  ExMCP invalidation envelopes produced after an upstream restart:

  - HTTP 400 with the exact negotiated-version mismatch for the held protocol
  - HTTP 404 with JSON-RPC invalid-request message `Session not found`
  """
  @spec http_session_invalidated?(map(), binary(), integer(), binary() | nil) :: boolean()
  def http_session_invalidated?(session, request_body, status, response_body)
      when is_map(session) and is_binary(request_body) and is_binary(response_body) and
             status in [400, 404] do
    existing_session?(session) and
      not initialize_request?(request_body) and
      byte_size(response_body) <= @max_invalidation_body_bytes and
      invalidation_response?(session, status, response_body)
  end

  def http_session_invalidated?(_session, _request_body, _status, _response_body), do: false

  @doc """
  Extra headers the proxy must replay on later POSTs to the same session.
  """
  @spec extra_forward_headers(map()) :: [{String.t(), String.t()}]
  def extra_forward_headers(session) when is_map(session) do
    []
    |> maybe_header(@session_header, Map.get(session, :session_id))
    |> maybe_header(@protocol_header, Map.get(session, :protocol_version))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_header(headers, _name, value) when value in [nil, ""], do: headers
  defp maybe_header(headers, name, value) when is_binary(value), do: headers ++ [{name, value}]

  defp maybe_cache_initialized(session, body) do
    if initialized_notification?(body) and is_binary(Map.get(session, :cached_initialize_body)) do
      Map.put(session, :cached_initialized_body, body)
    else
      session
    end
  end

  defp build_recovery_plan(session, initialize_body, initialized_body, expected_protocol) do
    case parse_initialize_request(initialize_body) do
      {:initialize, _requested_protocol} ->
        if initialized_notification?(initialized_body) do
          recovery_session =
            session
            |> Map.put(:session_id, nil)
            |> Map.put(:protocol_version, expected_protocol)
            |> Map.put(:cached_initialize_body, nil)
            |> Map.put(:cached_initialized_body, nil)

          plan = %{
            initialize_body: initialize_body,
            initialized_body: initialized_body,
            expected_protocol: expected_protocol
          }

          {:ok, recovery_session, plan}
        else
          {:error, :incomplete_cached_lifecycle}
        end

      :other ->
        {:error, :incomplete_cached_lifecycle}
    end
  end

  defp validate_recovery_session(session, expected_protocol) do
    cond do
      not existing_session?(session) ->
        {:error, :missing_recovery_session_id}

      Map.get(session, :protocol_version) != expected_protocol ->
        {:error, {:incompatible_protocol, expected_protocol, Map.get(session, :protocol_version)}}

      true ->
        :ok
    end
  end

  defp parse_initialize_request(body) do
    case Jason.decode(body) do
      {:ok, %{"method" => "initialize"} = request} ->
        version =
          case Map.get(request, "params") do
            %{"protocolVersion" => version} when is_binary(version) and version != "" -> version
            _other -> nil
          end

        {:initialize, version}

      _other ->
        :other
    end
  end

  defp initialize_request?(body),
    do: match?({:initialize, _version}, parse_initialize_request(body))

  defp initialized_notification?(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"method" => "notifications/initialized"} = request} ->
        not Map.has_key?(request, "id")

      _other ->
        false
    end
  end

  defp protocol_version_from_initialize_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"result" => %{"protocolVersion" => version}}}
      when is_binary(version) and version != "" ->
        version

      _other ->
        nil
    end
  end

  defp protocol_version_from_initialize_response(_body), do: nil

  defp existing_session?(session) do
    case Map.get(session, :session_id) do
      session_id when is_binary(session_id) and session_id != "" -> true
      _other -> false
    end
  end

  defp invalidation_response?(session, status, body) do
    case Jason.decode(body) do
      {:ok,
       %{
         "jsonrpc" => "2.0",
         "id" => nil,
         "error" => %{"code" => -32_600} = error
       }} ->
        invalidation_error?(session, status, error)

      _other ->
        false
    end
  end

  defp invalidation_error?(_session, 404, %{"message" => "Session not found"}), do: true

  defp invalidation_error?(
         %{protocol_version: current_version},
         400,
         %{
           "message" => message,
           "data" => %{"expectedVersion" => expected_version}
         }
       )
       when is_binary(current_version) and current_version != "" and
              is_binary(expected_version) and expected_version != "" and is_binary(message) do
    message ==
      "MCP-Protocol-Version #{current_version} does not match the negotiated version #{expected_version}."
  end

  defp invalidation_error?(_session, _status, _error), do: false

  defp fetch_header(headers, name) do
    Enum.find_value(headers, fn
      {key, value} ->
        if header_name_eq?(key, name), do: nonempty_header_value(value)

      _other ->
        nil
    end)
  end

  defp header_name_eq?(key, name) when is_list(key),
    do: header_name_eq?(List.to_string(key), name)

  defp header_name_eq?(key, name) when is_atom(key),
    do: header_name_eq?(Atom.to_string(key), name)

  defp header_name_eq?(key, name) when is_binary(key),
    do: String.downcase(key) == name

  defp header_name_eq?(_key, _name), do: false

  defp nonempty_header_value(value) when is_list(value),
    do: nonempty_header_value(List.to_string(value))

  defp nonempty_header_value(value) when is_binary(value) and value != "", do: value
  defp nonempty_header_value(_value), do: nil
end
