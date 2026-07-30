defmodule Arbor.Security.OIDC.Discovery do
  @moduledoc """
  OIDC provider discovery with a **closed** endpoint-trust policy.

  `Arbor.Common.OAuth.AuthCode` is deliberately provider-neutral and trusts the
  endpoints it is handed. This module is where that trust is earned. It owns
  the whole decision about which endpoints Security is willing to send a
  `client_secret`, an authorization code, and a PKCE verifier to.

  ## Policy

  1. **Issuer shape and scheme are validated before any network IO.** An
     unsafe issuer never opens a socket.
  2. Discovery is fetched through the bounded
     `Arbor.Common.OAuth.HttpClient` (no redirects, no compression, no retry,
     byte-capped).
  3. **Issuer-same-origin, closed.** The discovered `authorization_endpoint`
     and `token_endpoint` must sit on exactly the issuer's origin
     (`{scheme, host, effective_port}`). This is the gate that stops a
     compromised or hostile `.well-known` document from redirecting
     credentials to another host.
  4. A `"issuer"` field in the document must match the requested issuer
     (RFC 8414 §3.3), compared trailing-slash-insensitively.
  5. Callers may widen trust explicitly — never implicitly — with
     `:trusted_origins` or by pinning `:endpoints` outright.

  Rejected endpoints are never echoed back in the error term.
  """

  alias Arbor.Common.OAuth.HttpClient
  alias Arbor.Common.OAuth.HttpClient.Request

  @discovery_max_response_bytes 262_144
  @discovery_timeout_ms 10_000
  @max_issuer_bytes 2_048
  @min_endpoint_port 1
  @max_endpoint_port 65_535
  @max_discovery_options 128
  @max_discovery_endpoints 32
  @max_trusted_origins 32
  @max_origin_bytes 2_048
  @max_pinned_endpoint_bytes 2_048

  @type endpoints :: %{
          issuer: String.t(),
          authorization_endpoint: String.t() | nil,
          token_endpoint: String.t() | nil
        }

  @doc """
  Resolve an issuer's authorization and token endpoints under the closed policy.

  An endpoint absent from the document is returned as `nil` — the caller
  decides whether the one it needs is required (this preserves the historical
  behaviour where building an authorize URL did not require a token endpoint,
  and vice versa). An endpoint that *is* present must pass the origin gate.

  ## Options

    * `:allow_http` — permit an `http://` issuer (loopback/dev). Default `false`.
    * `:endpoints` — pin endpoints and skip discovery entirely. A map with
      `:authorization_endpoint` and/or `:token_endpoint`.
    * `:trusted_origins` — additional origins accepted alongside the issuer's.
    * `:http_client` — `Arbor.Common.OAuth.HttpClient` adapter override.
    * `:max_response_bytes`, `:timeout_ms` — budget overrides.
  """
  @spec discover(term(), term()) :: {:ok, endpoints()} | {:error, term()}
  def discover(issuer, opts \\ []) do
    with {:ok, normalized_opts} <- normalize_options(opts),
         :ok <- validate_operation(normalized_opts.for),
         {:ok, normalized} <- validate_issuer(issuer, normalized_opts.allow_http),
         {:ok, document, source} <- fetch_document(normalized, normalized_opts),
         :ok <- verify_document_issuer(document, normalized, source),
         {:ok, authorize} <-
           endpoint_for_operation(
             document,
             "authorization_endpoint",
             normalized_opts.for,
             :authorize,
             normalized,
             normalized_opts
           ),
         {:ok, token} <-
           endpoint_for_operation(
             document,
             "token_endpoint",
             normalized_opts.for,
             :token,
             normalized,
             normalized_opts
           ) do
      {:ok, %{issuer: normalized, authorization_endpoint: authorize, token_endpoint: token}}
    end
  end

  # --- Option normalization/validation ---

  defp normalize_options(opts) when is_list(opts) do
    normalize_options(opts, @max_discovery_options, %{})
  end

  defp normalize_options(opts) when is_map(opts) and not is_struct(opts) do
    if map_size(opts) > @max_discovery_options do
      {:error, {:invalid_discovery_options, :too_many_options}}
    else
      normalize_options(Map.to_list(opts), @max_discovery_options, %{})
    end
  end

  defp normalize_options(_opts), do: {:error, {:invalid_discovery_options, :invalid_opts}}

  defp normalize_options([], _remaining, acc) do
    allow_http = Map.get(acc, :allow_http, false)
    operation = Map.get(acc, :for, :both)
    max_response_bytes = Map.get(acc, :max_response_bytes, @discovery_max_response_bytes)
    timeout_ms = Map.get(acc, :timeout_ms, @discovery_timeout_ms)
    http_client = Map.get(acc, :http_client)

    with :ok <- validate_bool_option(:allow_http, allow_http),
         :ok <-
           validate_discovery_range(
             max_response_bytes,
             @discovery_max_response_bytes,
             :max_response_bytes
           ),
         :ok <- validate_discovery_range(timeout_ms, @discovery_timeout_ms, :timeout_ms),
         :ok <- validate_discovery_http_client(http_client),
         {:ok, endpoints} <- validate_endpoints_option(Map.get(acc, :endpoints), allow_http),
         {:ok, trusted_origins} <-
           validate_trusted_origins(Map.get(acc, :trusted_origins, []), allow_http) do
      {:ok,
       %{
         allow_http: allow_http,
         for: operation,
         http_client: http_client,
         max_response_bytes: max_response_bytes,
         timeout_ms: timeout_ms,
         endpoints: endpoints,
         trusted_origins: trusted_origins
       }}
    end
  end

  defp normalize_options(_items, remaining, _acc) when remaining <= 0,
    do: {:error, {:invalid_discovery_options, :too_many_options}}

  defp normalize_options([{key, value} | rest], remaining, acc) when is_list(rest) do
    with {:ok, normalized_key} <- normalize_discovery_key(key),
         {:ok, _acc} <- duplicate_key_check(acc, normalized_key) do
      normalize_options(rest, remaining - 1, Map.put(acc, normalized_key, value))
    else
      {:error, :duplicate_key} ->
        {:error, {:invalid_discovery_options, :duplicate_key}}

      {:error, :unknown_key} ->
        {:error, {:invalid_discovery_options, :unknown_key}}
    end
  end

  defp normalize_options(_items, _remaining, _acc),
    do: {:error, {:invalid_discovery_options, :invalid_opts}}

  defp normalize_discovery_key(:allow_http), do: {:ok, :allow_http}
  defp normalize_discovery_key("allow_http"), do: {:ok, :allow_http}
  defp normalize_discovery_key(:for), do: {:ok, :for}
  defp normalize_discovery_key("for"), do: {:ok, :for}
  defp normalize_discovery_key(:endpoints), do: {:ok, :endpoints}
  defp normalize_discovery_key("endpoints"), do: {:ok, :endpoints}
  defp normalize_discovery_key(:trusted_origins), do: {:ok, :trusted_origins}
  defp normalize_discovery_key("trusted_origins"), do: {:ok, :trusted_origins}
  defp normalize_discovery_key(:http_client), do: {:ok, :http_client}
  defp normalize_discovery_key("http_client"), do: {:ok, :http_client}
  defp normalize_discovery_key(:max_response_bytes), do: {:ok, :max_response_bytes}
  defp normalize_discovery_key("max_response_bytes"), do: {:ok, :max_response_bytes}
  defp normalize_discovery_key(:timeout_ms), do: {:ok, :timeout_ms}
  defp normalize_discovery_key("timeout_ms"), do: {:ok, :timeout_ms}
  defp normalize_discovery_key(_), do: {:error, :unknown_key}

  defp duplicate_key_check(map, key) do
    if Map.has_key?(map, key),
      do: {:error, :duplicate_key},
      else: {:ok, map}
  end

  defp validate_discovery_range(value, max, _name)
       when is_integer(value) and value > 0 and value <= max, do: :ok

  defp validate_discovery_range(_value, _max, name),
    do: {:error, {:invalid_discovery_options, {name, :invalid_range}}}

  defp validate_bool_option(_name, value) when is_boolean(value), do: :ok

  defp validate_bool_option(name, _value),
    do: {:error, {:invalid_discovery_options, {name, :invalid_bool}}}

  defp validate_discovery_http_client(nil), do: :ok

  defp validate_discovery_http_client(client) when is_atom(client) do
    if Code.ensure_loaded?(client) and function_exported?(client, :request, 1),
      do: :ok,
      else: {:error, {:invalid_discovery_options, :http_client}}
  end

  defp validate_discovery_http_client(_client),
    do: {:error, {:invalid_discovery_options, :http_client}}

  # --- Endpoint pinning ---

  defp validate_endpoints_option(nil, _allow_http), do: {:ok, nil}

  defp validate_endpoints_option(endpoints, allow_http) when is_map(endpoints) do
    if map_size(endpoints) > @max_discovery_endpoints do
      {:error, {:invalid_discovery_options, :pinned_endpoints}}
    else
      validate_pinned_endpoints(Map.to_list(endpoints), allow_http, @max_discovery_endpoints, %{})
    end
  end

  defp validate_endpoints_option(_other, _allow_http),
    do: {:error, {:invalid_discovery_options, :pinned_endpoints}}

  defp validate_pinned_endpoints([], _allow_http, _remaining, acc), do: {:ok, acc}

  defp validate_pinned_endpoints(_pairs, _allow_http, remaining, _acc) when remaining <= 0,
    do: {:error, {:invalid_discovery_options, :pinned_endpoints}}

  defp validate_pinned_endpoints([{key, value} | rest], allow_http, remaining, acc)
       when is_list(rest) do
    with {:ok, normalized_key} <- normalize_pinned_endpoint_key(key),
         {:ok, _acc} <- duplicate_key_check(acc, normalized_key),
         {:ok, value} <- validate_pinned_endpoint_value(value, allow_http) do
      validate_pinned_endpoints(
        rest,
        allow_http,
        remaining - 1,
        Map.put(acc, normalized_key, value)
      )
    else
      {:error, :duplicate_key} ->
        {:error, {:invalid_discovery_options, :pinned_endpoints}}

      {:error, {:invalid_discovery_options, _reason}} = error ->
        error

      _other ->
        {:error, {:invalid_discovery_options, :pinned_endpoints}}
    end
  end

  defp validate_pinned_endpoints(_pairs, _allow_http, _remaining, _acc),
    do: {:error, {:invalid_discovery_options, :pinned_endpoints}}

  defp normalize_pinned_endpoint_key(:authorization_endpoint), do: {:ok, :authorization_endpoint}
  defp normalize_pinned_endpoint_key("authorization_endpoint"), do: {:ok, :authorization_endpoint}
  defp normalize_pinned_endpoint_key(:token_endpoint), do: {:ok, :token_endpoint}
  defp normalize_pinned_endpoint_key("token_endpoint"), do: {:ok, :token_endpoint}
  defp normalize_pinned_endpoint_key(_), do: {:error, :pinned_endpoint_key}

  defp validate_pinned_endpoint_value(nil, _allow_http), do: {:ok, nil}

  defp validate_pinned_endpoint_value(url, allow_http)
       when is_binary(url) and byte_size(url) > 0 and byte_size(url) <= @max_pinned_endpoint_bytes do
    result =
      with true <- safe_text?(url) and not has_raw_whitespace?(url),
           {:ok, uri} <- URI.new(url),
           :ok <- validate_endpoint_scheme(uri, allow_http),
           :ok <- validate_endpoint_port(uri),
           :ok <- validate_endpoint_userinfo(uri),
           :ok <- validate_endpoint_fragment(uri),
           :ok <- validate_host(uri.host) do
        {:ok, url}
      end

    case result do
      {:ok, ^url} = ok -> ok
      _other -> {:error, {:invalid_discovery_options, :pinned_endpoint}}
    end
  end

  defp validate_pinned_endpoint_value(_url, _allow_http),
    do: {:error, {:invalid_discovery_options, :pinned_endpoint}}

  # --- Trusted origins ---

  defp validate_trusted_origins(origins, allow_http) when is_list(origins) do
    validate_trusted_origins(origins, @max_trusted_origins, [], allow_http)
  end

  defp validate_trusted_origins(_origins, _allow_http),
    do: {:error, {:invalid_discovery_options, :trusted_origins}}

  defp validate_trusted_origins([], _remaining, acc, _allow_http), do: {:ok, Enum.reverse(acc)}

  defp validate_trusted_origins(_origins, remaining, _acc, _allow_http) when remaining <= 0,
    do: {:error, {:invalid_discovery_options, :trusted_origins}}

  defp validate_trusted_origins([origin | rest], remaining, acc, allow_http) when is_list(rest) do
    with {:ok, parsed} <- validate_origin(origin, allow_http) do
      validate_trusted_origins(rest, remaining - 1, [parsed | acc], allow_http)
    end
  end

  defp validate_trusted_origins(_origins, _remaining, _acc, _allow_http),
    do: {:error, {:invalid_discovery_options, :trusted_origins}}

  defp validate_origin(origin, allow_http) when is_binary(origin) do
    cond do
      byte_size(origin) > @max_origin_bytes ->
        {:error, {:invalid_discovery_options, :trusted_origins}}

      not safe_text?(origin) ->
        {:error, {:invalid_discovery_options, :trusted_origins}}

      has_raw_whitespace?(origin) ->
        {:error, {:invalid_discovery_options, :trusted_origins}}

      true ->
        case URI.new(origin) do
          {:ok, uri} ->
            case validate_trusted_origin_parts(uri, allow_http) do
              :ok ->
                {:ok,
                 {String.downcase(uri.scheme), String.downcase(uri.host), effective_port(uri)}}

              _ ->
                {:error, {:invalid_discovery_options, :trusted_origins}}
            end

          {:error, _reason} ->
            {:error, {:invalid_discovery_options, :trusted_origins}}
        end
    end
  end

  defp validate_origin(_origin, _allow_http),
    do: {:error, {:invalid_discovery_options, :trusted_origins}}

  defp validate_trusted_origin_parts(uri, allow_http) do
    with :ok <- trusted_origin_scheme(uri, allow_http),
         :ok <- trusted_origin_path(uri.path),
         :ok <- trusted_origin_port(uri),
         :ok <- trusted_origin_userinfo(uri.userinfo),
         :ok <- trusted_origin_query(uri.query),
         :ok <- trusted_origin_fragment(uri.fragment),
         :ok <- trusted_origin_host(uri.host) do
      :ok
    end
  end

  defp trusted_origin_scheme(%URI{scheme: "https"}, _allow_http), do: :ok
  defp trusted_origin_scheme(%URI{scheme: "http"}, true), do: :ok
  defp trusted_origin_scheme(_uri, _allow_http), do: {:error, :invalid}

  defp trusted_origin_port(uri), do: validate_endpoint_port(uri, :trusted_origin)

  defp trusted_origin_path(nil), do: :ok
  defp trusted_origin_path(""), do: :ok
  defp trusted_origin_path(_), do: {:error, :invalid}

  defp trusted_origin_userinfo(nil), do: :ok
  defp trusted_origin_userinfo(_), do: {:error, :invalid}

  defp trusted_origin_query(nil), do: :ok
  defp trusted_origin_query(_), do: {:error, :invalid}

  defp trusted_origin_fragment(nil), do: :ok
  defp trusted_origin_fragment(_), do: {:error, :invalid}

  defp trusted_origin_host(host) do
    case validate_host(host) do
      :ok -> :ok
      _ -> {:error, :invalid}
    end
  end

  @doc """
  Validate an issuer's shape and scheme. **Performs no IO.**

  Accepts ordinary issuers — root (`https://accounts.google.com`), trailing
  slash, path-bearing, and IPv6-literal hosts. There is deliberately no
  byte-identical reserialization requirement: that would reject legitimate
  percent-encoded and bracketed-IPv6 issuers while adding nothing the explicit
  component rules below don't already cover.

  Returns the issuer with any trailing slash removed.
  """
  @spec validate_issuer(term(), boolean()) :: {:ok, String.t()} | {:error, term()}
  def validate_issuer(issuer, allow_http \\ false)

  def validate_issuer(issuer, allow_http) when is_binary(issuer) do
    cond do
      issuer == "" ->
        {:error, {:invalid_issuer, :empty}}

      byte_size(issuer) > @max_issuer_bytes ->
        {:error, {:invalid_issuer, :too_long}}

      not safe_text?(issuer) ->
        {:error, {:invalid_issuer, :unsafe_characters}}

      has_raw_whitespace?(issuer) ->
        {:error, {:invalid_issuer, :unsafe_characters}}

      true ->
        parse_issuer(issuer, allow_http)
    end
  end

  def validate_issuer(_issuer, _allow_http), do: {:error, {:invalid_issuer, :binary_required}}

  @doc "The `.well-known` discovery URL for a validated issuer."
  @spec discovery_url(String.t()) :: String.t()
  def discovery_url(issuer) do
    String.trim_trailing(issuer, "/") <> "/.well-known/openid-configuration"
  end

  # --- Issuer shape ---

  defp parse_issuer(issuer, allow_http) do
    with {:ok, uri} <- issuer_uri(issuer),
         :ok <- issuer_scheme(uri, allow_http),
         :ok <- issuer_userinfo(uri),
         :ok <- issuer_host(uri),
         :ok <- issuer_port(uri),
         :ok <- issuer_no_query_or_fragment(uri),
         :ok <- issuer_path(uri) do
      {:ok, String.trim_trailing(issuer, "/")}
    end
  end

  defp issuer_uri(issuer) do
    case URI.new(issuer) do
      {:ok, uri} -> {:ok, uri}
      {:error, _part} -> {:error, {:invalid_issuer, :unparseable}}
    end
  end

  defp issuer_scheme(%URI{scheme: "https"}, _allow_http), do: :ok
  defp issuer_scheme(%URI{scheme: "http"}, true), do: :ok

  defp issuer_scheme(%URI{scheme: "http"}, _allow_http),
    do: {:error, {:invalid_issuer, :scheme_not_allowed}}

  defp issuer_scheme(%URI{scheme: nil}, _allow_http),
    do: {:error, {:invalid_issuer, :scheme_required}}

  defp issuer_scheme(%URI{}, _allow_http), do: {:error, {:invalid_issuer, :scheme_not_allowed}}

  defp issuer_userinfo(%URI{userinfo: nil}), do: :ok
  defp issuer_userinfo(%URI{}), do: {:error, {:invalid_issuer, :userinfo_not_allowed}}

  defp issuer_host(%URI{host: host}) when is_binary(host) and host != "" do
    if validate_host(host) == :ok, do: :ok, else: {:error, {:invalid_issuer, :invalid_host}}
  end

  defp issuer_host(%URI{}), do: {:error, {:invalid_issuer, :host_required}}

  defp issuer_port(%URI{port: nil}), do: :ok

  defp issuer_port(%URI{port: port}) when is_integer(port) and port >= 1 and port <= 65_535,
    do: :ok

  defp issuer_port(%URI{}), do: {:error, {:invalid_issuer, :invalid_port}}

  defp issuer_no_query_or_fragment(%URI{query: nil, fragment: nil}), do: :ok

  defp issuer_no_query_or_fragment(%URI{query: q}) when not is_nil(q),
    do: {:error, {:invalid_issuer, :query_not_allowed}}

  defp issuer_no_query_or_fragment(%URI{}), do: {:error, {:invalid_issuer, :fragment_not_allowed}}

  defp issuer_path(%URI{path: nil}), do: :ok
  defp issuer_path(%URI{path: ""}), do: :ok
  defp issuer_path(%URI{path: "/"}), do: :ok

  defp issuer_path(%URI{path: path}) do
    segments = path |> String.trim_trailing("/") |> String.split("/")

    cond do
      ".." in segments -> {:error, {:invalid_issuer, :dot_segment}}
      # A leading "/" yields an empty first segment; any other empty one is "//".
      Enum.any?(tl(segments), &(&1 == "")) -> {:error, {:invalid_issuer, :empty_path_segment}}
      true -> :ok
    end
  end

  defp safe_text?(text) do
    String.valid?(text) and Enum.all?(:binary.bin_to_list(text), &(&1 >= 0x20 and &1 != 0x7F))
  end

  defp has_raw_whitespace?(text), do: String.match?(text, ~r/\s/u)

  # --- Discovery fetch ---

  defp fetch_document(issuer, opts) do
    case opts.endpoints do
      nil ->
        with {:ok, document} <- fetch_remote_document(issuer, opts) do
          {:ok, document, :remote}
        end

      %{} = pinned ->
        {:ok, pinned_document(pinned), :pinned}

      _ ->
        {:error, {:invalid_discovery_options, :pinned_endpoints}}
    end
  end

  defp pinned_document(pinned) do
    %{}
    |> maybe_put_pinned("authorization_endpoint", Map.get(pinned, :authorization_endpoint))
    |> maybe_put_pinned("token_endpoint", Map.get(pinned, :token_endpoint))
  end

  defp maybe_put_pinned(doc, _key, nil), do: doc
  defp maybe_put_pinned(doc, key, value), do: Map.put(doc, key, value)

  defp fetch_remote_document(issuer, opts) do
    request = %Request{
      method: :get,
      url: discovery_url(issuer),
      headers: [{"accept", "application/json"}],
      max_response_bytes: opts.max_response_bytes,
      timeout_ms: opts.timeout_ms
    }

    case HttpClient.request(request, http_client: opts.http_client) do
      {:ok, %HttpClient.Response{status: 200, body: body}} ->
        decode_document(body)

      {:ok, %HttpClient.Response{status: status}} ->
        {:error, {:openid_config_fetch_failed, status}}

      {:error, _reason} = error ->
        error
    end
  end

  defp decode_document(body) do
    case Jason.decode(body) do
      {:ok, document} when is_map(document) -> {:ok, document}
      {:ok, _other} -> {:error, {:invalid_openid_config, :object_required}}
      {:error, _reason} -> {:error, {:invalid_openid_config, :malformed_json}}
    end
  end

  # --- Trust policy ---

  defp verify_document_issuer(_document, _issuer, :pinned), do: :ok

  defp verify_document_issuer(document, issuer, :remote) do
    case Map.fetch(document, "issuer") do
      {:ok, declared} when is_binary(declared) ->
        if String.trim_trailing(declared, "/") == issuer,
          do: :ok,
          else: {:error, {:untrusted_endpoint, :issuer_mismatch}}

      _missing_or_invalid ->
        {:error, {:untrusted_endpoint, :issuer_mismatch}}
    end
  end

  # An absent endpoint yields nil so the caller can require only what it needs.
  # A PRESENT endpoint always passes the origin gate — including a non-binary
  # one, which is untrusted rather than merely missing.
  defp trusted_endpoint(document, field, issuer, opts) do
    case Map.fetch(document, field) do
      {:ok, endpoint} when is_binary(endpoint) and endpoint != "" ->
        authorize_origin(endpoint, issuer, opts)

      {:ok, _other} ->
        {:error, {:untrusted_endpoint, :issuer_origin_mismatch}}

      :error ->
        {:ok, nil}
    end
  end

  defp authorize_origin(endpoint, issuer, opts) do
    with {:ok, endpoint_origin} <- origin(endpoint, opts.allow_http),
         {:ok, issuer_origin} <- origin(issuer, opts.allow_http) do
      allowed = [issuer_origin | opts.trusted_origins]

      if endpoint_origin in allowed,
        do: {:ok, endpoint},
        else: {:error, {:untrusted_endpoint, :issuer_origin_mismatch}}
    end
  end

  defp endpoint_for_operation(document, field, operation, kind, normalized, opts) do
    if applies_to_operation?(kind, operation) do
      trusted_endpoint(document, field, normalized, opts)
    else
      {:ok, nil}
    end
  end

  defp applies_to_operation?(:authorize, :authorize), do: true
  defp applies_to_operation?(:authorize, :both), do: true
  defp applies_to_operation?(:token, :token), do: true
  defp applies_to_operation?(:token, :both), do: true
  defp applies_to_operation?(_field, _operation), do: false

  defp validate_operation(:authorize), do: :ok
  defp validate_operation(:token), do: :ok
  defp validate_operation(:both), do: :ok
  defp validate_operation(_other), do: {:error, {:invalid_discovery_operation, :unsupported}}

  # An absolute-URL origin triple with default-port folding. Anything relative,
  # unparseable, or hostless is untrusted by construction.
  defp origin(url, allow_http) when is_binary(url) do
    result =
      with true <-
             byte_size(url) > 0 and byte_size(url) <= @max_pinned_endpoint_bytes and
               safe_text?(url) and not has_raw_whitespace?(url),
           {:ok, %URI{scheme: scheme, host: host} = uri} <- URI.new(url),
           true <- is_binary(scheme) and is_binary(host) and host != "",
           :ok <- validate_endpoint_scheme(uri, allow_http),
           :ok <- validate_endpoint_port(uri, :origin),
           :ok <- validate_endpoint_userinfo(uri),
           :ok <- validate_endpoint_fragment(uri),
           :ok <- validate_host(host) do
        {:ok, {String.downcase(scheme), String.downcase(host), effective_port(uri)}}
      end

    case result do
      {:ok, {_scheme, _host, _port}} = ok ->
        ok

      _malformed_or_untrusted ->
        {:error, {:untrusted_endpoint, :issuer_origin_mismatch}}
    end
  end

  defp origin(_url, _allow_http), do: {:error, {:untrusted_endpoint, :issuer_origin_mismatch}}

  defp validate_endpoint_scheme(%URI{scheme: "https"}, _allow_http), do: :ok
  defp validate_endpoint_scheme(%URI{scheme: "http"}, true), do: :ok

  defp validate_endpoint_scheme(%URI{scheme: "http"}, _allow_http),
    do: {:error, {:invalid_discovery_options, :endpoint_scheme_not_allowed}}

  defp validate_endpoint_scheme(%URI{scheme: nil}, _allow_http),
    do: {:error, {:invalid_discovery_options, :endpoint_scheme_required}}

  defp validate_endpoint_scheme(_uri, _allow_http),
    do: {:error, {:invalid_discovery_options, :invalid_endpoint_scheme}}

  defp validate_endpoint_userinfo(%URI{userinfo: nil}), do: :ok

  defp validate_endpoint_userinfo(_uri),
    do: {:error, {:invalid_discovery_options, :endpoint_with_userinfo}}

  defp validate_endpoint_fragment(%URI{fragment: nil}), do: :ok

  defp validate_endpoint_fragment(_uri),
    do: {:error, {:invalid_discovery_options, :endpoint_with_fragment}}

  defp validate_endpoint_port(uri), do: validate_endpoint_port(uri, :discovery_options)

  defp validate_endpoint_port(%URI{port: nil}, _context), do: :ok

  defp validate_endpoint_port(%URI{port: port}, _context)
       when is_integer(port) and port >= @min_endpoint_port and port <= @max_endpoint_port,
       do: :ok

  defp validate_endpoint_port(_uri, :origin),
    do: {:error, {:untrusted_endpoint, :issuer_origin_mismatch}}

  defp validate_endpoint_port(_uri, :trusted_origin), do: {:error, :invalid}

  defp validate_endpoint_port(_uri, _context),
    do: {:error, {:invalid_discovery_options, :endpoint_port}}

  defp effective_port(%URI{port: port}) when is_integer(port), do: port
  defp effective_port(%URI{scheme: "https"}), do: 443
  defp effective_port(%URI{scheme: "http"}), do: 80
  defp effective_port(%URI{}), do: 0

  # Keep this split small and explicit: hostnames and IP-literals are both
  # accepted, but IPv6 is only accepted when :inet can parse it.
  defp validate_host(host) when is_binary(host) do
    normalized = normalize_ipv6_host(host)

    cond do
      String.contains?(normalized, ":") ->
        case :inet.parse_address(String.to_charlist(normalized)) do
          {:ok, _} -> :ok
          {:error, _} -> {:error, {:untrusted_endpoint, :issuer_origin_mismatch}}
        end

      valid_dns_host?(normalized) ->
        :ok

      true ->
        {:error, {:untrusted_endpoint, :issuer_origin_mismatch}}
    end
  end

  defp validate_host(_host), do: {:error, {:untrusted_endpoint, :issuer_origin_mismatch}}

  defp normalize_ipv6_host(host) do
    cond do
      String.starts_with?(host, "[") and String.ends_with?(host, "]") ->
        String.slice(host, 1, String.length(host) - 2)

      true ->
        host
    end
  end

  defp valid_dns_host?(host) do
    Regex.match?(
      ~r/\A(?:[A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]*[A-Za-z0-9])(?:\.(?:[A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]*[A-Za-z0-9]))*\z/,
      host
    )
  end
end
