defmodule Arbor.Common.OAuth.AuthCode do
  @moduledoc """
  Provider-neutral OAuth 2.0 authorization-code + PKCE acquisition primitive.

  This module is deliberately ignorant of providers. It performs **no**
  discovery, holds **no** endpoint allowlist, and never decides whether an
  endpoint is trustworthy — the caller supplies endpoints it has already
  validated. That split is what lets a single hardened boundary serve both
  `Arbor.Security.OIDC` and future provider-login callers without either of
  them depending on the other.

  What it does own:

    * RFC 7636 PKCE verifier/challenge derivation (S256) and CSRF state
    * total validation of every caller-supplied parameter, including
      `extra_query`, so arbitrary terms can neither crash it nor override a
      reserved OAuth key
    * correct authorization-URL composition when the endpoint already carries
      a query
    * a bounded token exchange whose failures never carry credential or
      provider-body material

  ## Params

  A keyword list or map with a **closed** key set. Unknown keys are rejected
  with the generic `{:error, {:invalid_params, :unknown_key}}`; arbitrary key
  terms are never reflected into diagnostics.

      :authorization_endpoint  :token_endpoint  :client_id  :client_secret
      :redirect_uri  :scopes  :state  :code  :code_verifier  :code_challenge
      :code_challenge_method  :extra_query  :response_schema
      :max_response_bytes  :timeout_ms  :allow_http  :http_client
  """

  alias Arbor.Common.OAuth.HttpClient
  alias Arbor.Common.OAuth.HttpClient.Request

  @reserved_query_keys ~w(
    response_type client_id redirect_uri scope state code_challenge code_challenge_method
  )

  @schema_types [
    :required_string,
    :optional_string,
    :optional_integer,
    :optional_number,
    :optional_boolean
  ]

  @default_max_response_bytes 65_536
  @default_timeout_ms 10_000

  @max_http_range 1_048_576
  @max_timeout_ms 120_000
  @max_params 128
  @max_param_pairs 128

  @max_client_id_bytes 2_048
  @max_client_secret_bytes 4_096
  @max_redirect_uri_bytes 2_048
  @max_state_bytes 1_024
  @max_code_bytes 1_024
  @max_code_verifier_bytes 1_024
  @max_code_challenge_bytes 1_024
  @max_endpoint_bytes 2_048

  @max_scopes 32
  @max_scope_bytes 128

  @max_response_schema_fields 64
  @max_response_schema_field_bytes 128

  @max_extra_query_pairs 16
  @max_extra_query_key_bytes 128
  @max_extra_query_value_bytes 2_048

  @max_token_keys 64
  @max_token_depth 4
  @max_token_value_bytes 8_192
  @max_token_key_bytes 128

  defmodule Params do
    @moduledoc """
    Normalized, validated OAuth parameters.

    Credential-bearing fields render as `"[REDACTED]"`; the struct is safe to
    `inspect/1` in a log line or an exception message.
    """

    defstruct authorization_endpoint: nil,
              token_endpoint: nil,
              client_id: nil,
              client_secret: nil,
              redirect_uri: nil,
              scopes: [],
              state: nil,
              code: nil,
              code_verifier: nil,
              code_challenge: nil,
              code_challenge_method: "S256",
              extra_query: [],
              response_schema: nil,
              max_response_bytes: nil,
              timeout_ms: nil,
              allow_http: false,
              http_client: nil

    @type t :: %__MODULE__{}

    defimpl Inspect do
      import Inspect.Algebra

      @redacted [:client_secret, :code, :code_verifier, :state]

      def inspect(params, opts) do
        fields =
          params
          |> Map.from_struct()
          |> Enum.map(fn
            {key, value} when key in @redacted ->
              {key, if(is_nil(value), do: nil, else: "[REDACTED]")}

            pair ->
              pair
          end)
          |> Enum.sort()

        concat(["#Arbor.Common.OAuth.AuthCode.Params<", to_doc(fields, opts), ">"])
      end
    end
  end

  @doc """
  Generate an RFC 7636 PKCE `{code_verifier, code_challenge}` pair.

  The verifier is 32 random bytes base64url-encoded without padding (43
  characters); the challenge is the base64url-encoded SHA-256 of the verifier
  (the `S256` method).
  """
  @spec generate_pkce() :: {String.t(), String.t()}
  def generate_pkce do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
    {verifier, challenge}
  end

  @doc "Generate a random CSRF `state` value."
  @spec generate_state() :: String.t()
  def generate_state do
    Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  @doc """
  Constant-time comparison of a returned `state` against the expected value.

  Returns `{:error, :state_mismatch}` for any non-binary, `nil`, empty, or
  length-mismatched input rather than raising, so a hostile callback cannot
  turn state checking into a crash.
  """
  @spec verify_state(term(), term()) :: :ok | {:error, :state_mismatch}
  def verify_state(received, expected)
      when is_binary(received) and is_binary(expected) and
             byte_size(received) > 0 and byte_size(expected) > 0 do
    if byte_size(received) == byte_size(expected) and :crypto.hash_equals(received, expected),
      do: :ok,
      else: {:error, :state_mismatch}
  end

  def verify_state(_received, _expected), do: {:error, :state_mismatch}

  @doc """
  Build an authorization-code + PKCE authorization URL.

  The endpoint is treated as caller-trusted for *origin* purposes but is still
  screened for shape: scheme, host, no fragment, and — critically — no
  reserved OAuth key already present in its query. A pre-existing
  `redirect_uri`/`state`/`code_challenge` pair would produce a duplicate
  parameter that a first-wins server resolves in the attacker's favour.
  """
  @spec build_authorize_url(keyword() | map()) :: {:ok, String.t()} | {:error, term()}
  def build_authorize_url(params) do
    with {:ok, params} <- normalize(params),
         :ok <- validate_request_options(params),
         :ok <-
           validate_text(
             client_id: {params.client_id, @max_client_id_bytes},
             state: {params.state, @max_state_bytes},
             code_challenge: {params.code_challenge, @max_code_challenge_bytes}
           ),
         :ok <- validate_uri_text(params.redirect_uri, @max_redirect_uri_bytes),
         :ok <- validate_scopes(params.scopes),
         :ok <- validate_challenge_method(params.code_challenge_method),
         {:ok, extra_pairs} <- validate_extra_query(params.extra_query),
         :ok <- parse_endpoint(params.authorization_endpoint, params.allow_http),
         :ok <- screen_existing_query(params.authorization_endpoint) do
      {:ok,
       compose_authorize_url(
         params.authorization_endpoint,
         params.scopes,
         params.client_id,
         params.redirect_uri,
         params.state,
         params.code_challenge,
         params.code_challenge_method,
         extra_pairs
       )}
    end
  end

  @doc """
  Exchange an authorization code for tokens at a caller-trusted token endpoint.

  `:response_schema` is **required** and is validated before any socket is
  opened — a malformed schema fails closed rather than degrading into
  "return whatever the provider sent".

  The schema *validates*; it does not project. On success the decoded body is
  returned in full with its original string keys, including fields the schema
  does not mention. On a non-200 the error carries the **status only** — the
  provider body is never decoded, logged, or returned.
  """
  @spec exchange_code(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def exchange_code(params) do
    with {:ok, params} <- normalize(params),
         :ok <- validate_request_options(params),
         {:ok, schema} <- validate_response_schema(params.response_schema),
         :ok <-
           validate_text(
             token_endpoint: {params.token_endpoint, @max_endpoint_bytes},
             client_id: {params.client_id, @max_client_id_bytes},
             code: {params.code, @max_code_bytes},
             redirect_uri: {params.redirect_uri, @max_redirect_uri_bytes}
           ),
         :ok <- validate_uri_text(params.redirect_uri, @max_redirect_uri_bytes),
         :ok <- validate_code_verifier(params.code_verifier),
         :ok <- parse_endpoint(params.token_endpoint, params.allow_http),
         {:ok, response} <- post_token(params) do
      handle_token_response(response, schema)
    end
  end

  @doc "The OAuth query keys this module owns and refuses to let a caller override."
  @spec reserved_query_keys() :: [String.t()]
  def reserved_query_keys, do: @reserved_query_keys

  # --- Params normalization ---

  defp normalize(params) when is_list(params) do
    normalize_option_list(params, @max_param_pairs, %{})
  end

  defp normalize(params) when is_map(params) and not is_struct(params) do
    if map_size(params) > @max_params do
      {:error, {:invalid_params, :too_many_params}}
    else
      normalize_known_keys(Map.to_list(params), @max_param_pairs, %{})
    end
  end

  defp normalize(_params), do: {:error, {:invalid_params, :keyword_or_map_required}}

  defp normalize_option_list([], _remaining, acc), do: build_params(acc)

  defp normalize_option_list([{key, value} | rest], remaining, acc) when is_list(rest) do
    cond do
      remaining <= 0 ->
        {:error, {:invalid_params, :too_many_params}}

      true ->
        with {:ok, normalized_key} <- normalize_key(key),
             {:ok, acc} <- duplicate_key_check(acc, normalized_key) do
          normalize_option_list(rest, remaining - 1, Map.put(acc, normalized_key, value))
        else
          {:error, :unknown_key} ->
            {:error, {:invalid_params, :unknown_key}}

          {:error, :duplicate_key} ->
            {:error, {:invalid_params, :duplicate_key}}
        end
    end
  end

  defp normalize_option_list(_other, _remaining, _acc),
    do: {:error, {:invalid_params, :invalid_option_term}}

  defp normalize_known_keys([], _remaining, acc), do: build_params(acc)

  defp normalize_known_keys([{key, value} | rest], remaining, acc) when is_list(rest) do
    cond do
      remaining <= 0 ->
        {:error, {:invalid_params, :too_many_params}}

      true ->
        with {:ok, normalized_key} <- normalize_key(key),
             {:ok, acc} <- duplicate_key_check(acc, normalized_key) do
          normalize_known_keys(rest, remaining - 1, Map.put(acc, normalized_key, value))
        else
          {:error, :duplicate_key} ->
            {:error, {:invalid_params, :duplicate_key}}

          {:error, :unknown_key} ->
            {:error, {:invalid_params, :unknown_key}}

          {:error, _reason} ->
            {:error, {:invalid_params, :unknown_key}}
        end
    end
  end

  defp normalize_known_keys(_other, _remaining, _acc),
    do: {:error, {:invalid_params, :invalid_option_term}}

  defp build_params(normalized) do
    {:ok,
     struct(
       Params,
       normalized
       |> Map.put_new(:max_response_bytes, @default_max_response_bytes)
       |> Map.put_new(:timeout_ms, @default_timeout_ms)
     )}
  end

  defp normalize_key(:authorization_endpoint), do: {:ok, :authorization_endpoint}
  defp normalize_key(:token_endpoint), do: {:ok, :token_endpoint}
  defp normalize_key(:client_id), do: {:ok, :client_id}
  defp normalize_key(:client_secret), do: {:ok, :client_secret}
  defp normalize_key(:redirect_uri), do: {:ok, :redirect_uri}
  defp normalize_key(:scopes), do: {:ok, :scopes}
  defp normalize_key(:state), do: {:ok, :state}
  defp normalize_key(:code), do: {:ok, :code}
  defp normalize_key(:code_verifier), do: {:ok, :code_verifier}
  defp normalize_key(:code_challenge), do: {:ok, :code_challenge}
  defp normalize_key(:code_challenge_method), do: {:ok, :code_challenge_method}
  defp normalize_key(:extra_query), do: {:ok, :extra_query}
  defp normalize_key(:response_schema), do: {:ok, :response_schema}
  defp normalize_key(:max_response_bytes), do: {:ok, :max_response_bytes}
  defp normalize_key(:timeout_ms), do: {:ok, :timeout_ms}
  defp normalize_key(:allow_http), do: {:ok, :allow_http}
  defp normalize_key(:http_client), do: {:ok, :http_client}
  defp normalize_key("authorization_endpoint"), do: {:ok, :authorization_endpoint}
  defp normalize_key("token_endpoint"), do: {:ok, :token_endpoint}
  defp normalize_key("client_id"), do: {:ok, :client_id}
  defp normalize_key("client_secret"), do: {:ok, :client_secret}
  defp normalize_key("redirect_uri"), do: {:ok, :redirect_uri}
  defp normalize_key("scopes"), do: {:ok, :scopes}
  defp normalize_key("state"), do: {:ok, :state}
  defp normalize_key("code"), do: {:ok, :code}
  defp normalize_key("code_verifier"), do: {:ok, :code_verifier}
  defp normalize_key("code_challenge"), do: {:ok, :code_challenge}
  defp normalize_key("code_challenge_method"), do: {:ok, :code_challenge_method}
  defp normalize_key("extra_query"), do: {:ok, :extra_query}
  defp normalize_key("response_schema"), do: {:ok, :response_schema}
  defp normalize_key("max_response_bytes"), do: {:ok, :max_response_bytes}
  defp normalize_key("timeout_ms"), do: {:ok, :timeout_ms}
  defp normalize_key("allow_http"), do: {:ok, :allow_http}
  defp normalize_key("http_client"), do: {:ok, :http_client}
  defp normalize_key(_key), do: {:error, :unknown_key}

  defp duplicate_key_check(map, key) do
    if Map.has_key?(map, key),
      do: {:error, :duplicate_key},
      else: {:ok, map}
  end

  # --- Text validation ---

  defp validate_text(fields) do
    Enum.reduce_while(fields, :ok, fn
      {name, {value, max}}, :ok ->
        case validate_text_value(name, value, max) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:invalid_params, reason}}}
        end
    end)
  end

  defp validate_text_value(_name, nil, _max), do: {:error, :missing}

  defp validate_text_value(_name, value, max) when is_binary(value) do
    cond do
      value == "" ->
        {:error, :empty}

      byte_size(value) > max ->
        {:error, :too_long}

      not safe_query_text?(value) ->
        {:error, :unsafe_characters}

      true ->
        :ok
    end
  end

  defp validate_text_value(_name, _value, _max), do: {:error, :invalid_type}

  defp validate_uri_text(value, max) do
    case validate_text_value(:uri, value, max) do
      :ok ->
        if has_raw_whitespace?(value),
          do: {:error, {:invalid_params, :unsafe_characters}},
          else: :ok

      {:error, reason} ->
        {:error, {:invalid_params, reason}}
    end
  end

  defp validate_code_verifier(""), do: :ok

  defp validate_code_verifier(value) do
    case validate_text_value(:code_verifier, value, @max_code_verifier_bytes) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_params, reason}}
    end
  end

  # --- Request/response option validation ---

  defp validate_request_options(params) do
    with :ok <- validate_client_secret(params.client_secret),
         :ok <- validate_allow_http(params.allow_http),
         :ok <- validate_http_client(params.http_client),
         :ok <- validate_range(params.max_response_bytes, @max_http_range, :max_response_bytes),
         :ok <- validate_range(params.timeout_ms, @max_timeout_ms, :timeout_ms) do
      :ok
    end
  end

  defp validate_client_secret(nil), do: :ok

  defp validate_client_secret(secret) when is_binary(secret) do
    if secret != "" and byte_size(secret) <= @max_client_secret_bytes and
         safe_query_text?(secret),
       do: :ok,
       else: {:error, {:invalid_params, :invalid_client_secret}}
  end

  defp validate_client_secret(_secret), do: {:error, {:invalid_params, :invalid_client_secret}}

  defp validate_allow_http(allow_http) when is_boolean(allow_http), do: :ok
  defp validate_allow_http(_allow_http), do: {:error, {:invalid_params, :invalid_allow_http}}

  defp validate_http_client(nil), do: :ok

  defp validate_http_client(client) when is_atom(client) do
    if Code.ensure_loaded?(client) and function_exported?(client, :request, 1) do
      :ok
    else
      {:error, {:invalid_params, :invalid_http_client}}
    end
  end

  defp validate_http_client(_client), do: {:error, {:invalid_params, :invalid_http_client}}

  defp validate_range(value, max_value, _name)
       when is_integer(value) and value > 0 and value <= max_value,
       do: :ok

  defp validate_range(_value, _max_value, name),
    do: {:error, {:invalid_params, {name, :invalid_range}}}

  # --- scope validation ---

  defp validate_scopes(nil), do: :ok

  defp validate_scopes(scopes) when is_list(scopes) do
    validate_scopes(scopes, @max_scopes)
  end

  defp validate_scopes(_scopes), do: {:error, {:invalid_params, :invalid_scopes}}

  defp validate_scopes([], _), do: :ok

  defp validate_scopes(_scopes, remaining) when remaining <= 0,
    do: {:error, {:invalid_params, :too_many_scopes}}

  defp validate_scopes([scope | rest], remaining) when is_list(rest) do
    with :ok <- validate_scope(scope),
         :ok <- validate_scopes(rest, remaining - 1) do
      :ok
    end
  end

  defp validate_scopes(_scope, _remaining), do: {:error, {:invalid_params, :invalid_scopes}}

  defp validate_scope(scope) when is_binary(scope) do
    cond do
      scope == "" ->
        {:error, {:invalid_params, :invalid_scopes}}

      byte_size(scope) > @max_scope_bytes ->
        {:error, {:invalid_params, :invalid_scopes}}

      not safe_query_text?(scope) ->
        {:error, {:invalid_params, :invalid_scopes}}

      String.match?(scope, ~r/\s/u) ->
        {:error, {:invalid_params, :invalid_scopes}}

      true ->
        :ok
    end
  end

  defp validate_scope(_scope), do: {:error, {:invalid_params, :invalid_scopes}}

  defp validate_challenge_method(method) when method in ["S256", "plain"], do: :ok

  defp validate_challenge_method(_method),
    do: {:error, {:invalid_params, :invalid_challenge_method}}

  # --- extra_query ---

  @doc false
  @spec validate_extra_query(term()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def validate_extra_query(nil), do: {:ok, []}

  def validate_extra_query(extra) when is_map(extra) and not is_struct(extra) do
    if map_size(extra) > @max_extra_query_pairs do
      {:error, {:invalid_extra_query, :too_many_pairs}}
    else
      validate_extra_query(Map.to_list(extra), @max_extra_query_pairs, [], MapSet.new())
    end
  end

  def validate_extra_query(extra) when is_list(extra) do
    validate_extra_query(extra, @max_extra_query_pairs, [], MapSet.new())
  end

  def validate_extra_query(_extra), do: {:error, {:invalid_extra_query, :map_or_list_required}}

  defp validate_extra_query([], _remaining, acc, _seen), do: {:ok, Enum.reverse(acc)}

  defp validate_extra_query(_extra, remaining, _acc, _seen) when remaining <= 0,
    do: {:error, {:invalid_extra_query, :too_many_pairs}}

  defp validate_extra_query([{key, value} | rest], remaining, acc, seen) when is_list(rest) do
    with {:ok, key} <- extra_key(key),
         {:ok, value} <- extra_value(value),
         :ok <- extra_not_reserved(key),
         :ok <- extra_not_duplicate(key, seen) do
      validate_extra_query(rest, remaining - 1, [{key, value} | acc], MapSet.put(seen, key))
    else
      {:error, _reason} = error -> error
      _ -> {:error, {:invalid_extra_query, :pair_required}}
    end
  end

  defp validate_extra_query(_other, _remaining, _acc, _seen),
    do: {:error, {:invalid_extra_query, :pair_required}}

  # Atoms are converted explicitly. Every other term is rejected WITHOUT calling
  # to_string/1, which raises for tuples, pids, refs, funs, and improper lists.
  defp extra_key(key) when is_atom(key) and not is_boolean(key) and not is_nil(key) do
    extra_key(Atom.to_string(key))
  end

  defp extra_key(key) when is_binary(key) do
    cond do
      byte_size(key) < 1 or byte_size(key) > @max_extra_query_key_bytes ->
        {:error, {:invalid_extra_query, :key_length}}

      not safe_query_text?(key) ->
        {:error, {:invalid_extra_query, :key_unsafe_characters}}

      true ->
        {:ok, key}
    end
  end

  defp extra_key(_key), do: {:error, {:invalid_extra_query, :invalid_key_type}}

  defp extra_value(value) when is_binary(value) do
    cond do
      byte_size(value) > @max_extra_query_value_bytes ->
        {:error, {:invalid_extra_query, :value_length}}

      not safe_query_text?(value) ->
        {:error, {:invalid_extra_query, :value_unsafe_characters}}

      true ->
        {:ok, value}
    end
  end

  defp extra_value(_value), do: {:error, {:invalid_extra_query, :invalid_value_type}}

  defp extra_not_reserved(key) do
    if key in @reserved_query_keys,
      do: {:error, {:invalid_extra_query, {:reserved_key, key}}},
      else: :ok
  end

  defp extra_not_duplicate(key, seen) do
    if MapSet.member?(seen, key),
      do: {:error, {:invalid_extra_query, :duplicate_key}},
      else: :ok
  end

  # Valid UTF-8, no control characters (which covers CR, LF, and NUL — a CRLF in
  # an unvalidated pair is a request-splitting primitive).
  defp safe_query_text?(text) when is_binary(text) do
    String.valid?(text) and Enum.all?(:binary.bin_to_list(text), &(&1 >= 0x20 and &1 != 0x7F))
  end

  defp has_raw_whitespace?(text) when is_binary(text) do
    String.match?(text, ~r/\s/)
  end

  defp has_raw_whitespace?(_text), do: true

  # --- Endpoint shape ---

  defp parse_endpoint(endpoint, allow_http) when is_binary(endpoint) do
    cond do
      byte_size(endpoint) > @max_endpoint_bytes ->
        {:error, {:invalid_endpoint, :too_long}}

      has_raw_whitespace?(endpoint) ->
        {:error, {:invalid_endpoint, :unsafe_characters}}

      not safe_query_text?(endpoint) ->
        {:error, {:invalid_endpoint, :unsafe_characters}}

      true ->
        with {:ok, uri} <- uri_new(endpoint),
             :ok <- endpoint_scheme(uri, allow_http),
             :ok <- validate_uri_host(uri),
             :ok <- endpoint_fragment(uri),
             :ok <- endpoint_port(uri) do
          :ok
        end
    end
  end

  defp parse_endpoint(_endpoint, _allow_http), do: {:error, {:invalid_endpoint, :binary_required}}

  defp uri_new(endpoint) do
    case URI.new(endpoint) do
      {:ok, uri} -> {:ok, uri}
      {:error, _part} -> {:error, {:invalid_endpoint, :unparseable}}
    end
  end

  defp endpoint_scheme(%URI{scheme: "https"}, _allow_http), do: :ok
  defp endpoint_scheme(%URI{scheme: "http"}, true), do: :ok

  defp endpoint_scheme(%URI{scheme: nil}, _allow_http),
    do: {:error, {:invalid_endpoint, :scheme_required}}

  defp endpoint_scheme(%URI{scheme: _}, _allow_http),
    do: {:error, {:invalid_endpoint, :scheme_not_allowed}}

  defp validate_uri_host(%URI{host: host, userinfo: nil}) when is_binary(host) and host != "" do
    validate_host(host)
  end

  defp validate_uri_host(%URI{userinfo: info}) when not is_nil(info),
    do: {:error, {:invalid_endpoint, :userinfo_not_allowed}}

  defp validate_uri_host(%URI{}), do: {:error, {:invalid_endpoint, :host_required}}

  defp endpoint_fragment(%URI{fragment: nil}), do: :ok
  defp endpoint_fragment(%URI{}), do: {:error, {:invalid_endpoint, :fragment_not_allowed}}

  defp endpoint_port(%URI{port: nil}), do: :ok

  defp endpoint_port(%URI{port: port})
       when is_integer(port) and port >= 1 and port <= 65_535,
       do: :ok

  defp endpoint_port(%URI{}), do: {:error, {:invalid_endpoint, :invalid_port}}

  # IPv6 validation is delegated to :inet.parse_address. DNS names remain
  # accepted through hostname checks to avoid breaking non-IP issuers.
  defp validate_host(host) when is_binary(host) do
    normalized = normalize_ipv6_host(host)

    cond do
      String.contains?(normalized, ":") ->
        case :inet.parse_address(String.to_charlist(normalized)) do
          {:ok, _} -> :ok
          {:error, _} -> {:error, {:invalid_endpoint, :invalid_host}}
        end

      valid_dns_host?(normalized) ->
        :ok

      true ->
        {:error, {:invalid_endpoint, :invalid_host}}
    end
  end

  defp validate_host(_host), do: {:error, {:invalid_endpoint, :invalid_host}}

  defp normalize_ipv6_host(host) do
    cond do
      String.starts_with?(host, "[") and String.ends_with?(host, "]") ->
        String.slice(host, 1, byte_size(host) - 2)

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

  defp screen_existing_query(%URI{query: query}) when is_binary(query) and query != "" do
    query
    |> URI.query_decoder()
    |> Enum.reduce_while(:ok, fn {key, _value}, :ok ->
      if key in @reserved_query_keys,
        do: {:halt, {:error, {:invalid_endpoint, {:reserved_query_key, key}}}},
        else: {:cont, :ok}
    end)
  rescue
    ArgumentError -> {:error, {:invalid_endpoint, :unparseable_query}}
  end

  defp screen_existing_query(%URI{}), do: :ok

  defp screen_existing_query(endpoint) when is_binary(endpoint) do
    endpoint
    |> URI.parse()
    |> screen_existing_query()
  end

  # --- URL composition ---

  defp compose_authorize_url(
         authorization_endpoint,
         scopes,
         client_id,
         redirect_uri,
         state,
         code_challenge,
         code_challenge_method,
         extra_pairs
       ) do
    with {:ok, uri} <- URI.new(authorization_endpoint) do
      reserved =
        [
          {"response_type", "code"},
          {"client_id", client_id},
          {"redirect_uri", redirect_uri},
          {"state", state},
          {"code_challenge", code_challenge},
          {"code_challenge_method", code_challenge_method}
        ]
        |> maybe_put_scope(scopes)

      new_query = URI.encode_query(extra_pairs ++ reserved)

      # The endpoint's own query is preserved VERBATIM (not re-encoded) so opaque
      # provider parameters survive byte-for-byte.
      final_query =
        case uri.query do
          nil -> new_query
          "" -> new_query
          existing -> existing <> "&" <> new_query
        end

      URI.to_string(%{uri | query: final_query})
    end
  end

  defp maybe_put_scope(pairs, scopes) when scopes in [nil, []], do: pairs
  defp maybe_put_scope(pairs, scopes), do: pairs ++ [{"scope", Enum.join(scopes, " ")}]

  # --- response_schema (fail closed, pre-network) ---

  @doc false
  @spec validate_response_schema(term()) :: {:ok, map()} | {:error, term()}
  def validate_response_schema(schema)
      when is_map(schema) and not is_struct(schema) and map_size(schema) == 0,
      do: {:error, {:invalid_response_schema, :empty}}

  def validate_response_schema(schema)
      when is_map(schema) and not is_struct(schema) and
             map_size(schema) > @max_response_schema_fields,
      do: {:error, {:invalid_response_schema, :too_many_fields}}

  def validate_response_schema(schema) when is_map(schema) and not is_struct(schema) do
    Enum.reduce_while(schema, {:ok, schema}, fn {field, type}, acc ->
      cond do
        not is_binary(field) or field == "" ->
          {:halt, {:error, {:invalid_response_schema, :non_binary_field}}}

        byte_size(field) > @max_response_schema_field_bytes ->
          {:halt, {:error, {:invalid_response_schema, :field_name_too_long}}}

        not safe_query_text?(field) ->
          {:halt, {:error, {:invalid_response_schema, :unsafe_field_name}}}

        type not in @schema_types ->
          {:halt, {:error, {:invalid_response_schema, :unknown_type}}}

        true ->
          {:cont, acc}
      end
    end)
  end

  def validate_response_schema(nil), do: {:error, {:invalid_response_schema, :required}}
  def validate_response_schema(_schema), do: {:error, {:invalid_response_schema, :map_required}}

  # --- Token exchange ---

  defp post_token(%Params{} = params) do
    form =
      %{
        "grant_type" => "authorization_code",
        "client_id" => params.client_id,
        "code" => params.code,
        "redirect_uri" => params.redirect_uri,
        "code_verifier" => params.code_verifier
      }
      |> maybe_put_secret(params.client_secret)

    request = %Request{
      method: :post,
      url: params.token_endpoint,
      headers: [{"accept", "application/json"}],
      form: form,
      max_response_bytes: params.max_response_bytes,
      timeout_ms: params.timeout_ms
    }

    HttpClient.request(request, http_client: params.http_client)
  end

  defp maybe_put_secret(form, nil), do: form

  defp maybe_put_secret(form, secret) when is_binary(secret),
    do: Map.put(form, "client_secret", secret)

  defp handle_token_response(%HttpClient.Response{status: 200, body: body}, schema) do
    with {:ok, decoded} <- decode_token_body(body),
         :ok <- structural_budget(decoded),
         :ok <- apply_schema(decoded, schema) do
      {:ok, decoded}
    end
  end

  # Status only. The provider body is never decoded, logged, or returned.
  defp handle_token_response(%HttpClient.Response{status: status}, _schema) do
    {:error, {:token_exchange_failed, status}}
  end

  defp decode_token_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> {:error, {:invalid_token_response, :object_required}}
      {:error, _reason} -> {:error, {:invalid_token_response, :malformed_json}}
    end
  end

  # Reject the whole response rather than trimming it — silent field loss would
  # be worse than a loud failure.
  defp structural_budget(decoded), do: budget_walk(decoded, 1)

  defp budget_walk(_term, depth) when depth > @max_token_depth,
    do: {:error, {:invalid_token_response, :depth}}

  defp budget_walk(term, depth) when is_map(term) do
    if map_size(term) > @max_token_keys do
      {:error, {:invalid_token_response, :keys}}
    else
      Enum.reduce_while(term, :ok, fn {k, v}, :ok ->
        with :ok <- validate_token_key(k),
             :ok <- budget_walk(v, depth + 1) do
          {:cont, :ok}
        else
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp budget_walk(term, depth) when is_list(term) do
    validate_list(term, @max_token_keys, depth)
  end

  defp budget_walk(term, _depth) when is_binary(term) do
    if byte_size(term) > @max_token_value_bytes,
      do: {:error, {:invalid_token_response, :value_bytes}},
      else: :ok
  end

  defp budget_walk(_term, _depth), do: :ok

  defp validate_list([], _remaining, _depth), do: :ok

  defp validate_list(_items, remaining, _depth) when remaining <= 0,
    do: {:error, {:invalid_token_response, :list_items}}

  defp validate_list([item | rest], remaining, depth) when is_list(rest) do
    case budget_walk(item, depth + 1) do
      :ok -> validate_list(rest, remaining - 1, depth)
      error -> error
    end
  end

  defp validate_list(_items, _remaining, _depth),
    do: {:error, {:invalid_token_response, :list_items}}

  defp validate_token_key(key) when is_binary(key) and byte_size(key) <= @max_token_key_bytes,
    do: :ok

  defp validate_token_key(_key), do: {:error, {:invalid_token_response, :invalid_key}}

  # Validates declared fields; leaves undeclared fields untouched in the result.
  defp apply_schema(decoded, schema) do
    Enum.reduce_while(schema, :ok, fn {field, type}, :ok ->
      case check_field(Map.fetch(decoded, field), type) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:invalid_token_response, reason}}}
      end
    end)
  end

  defp check_field(:error, :required_string), do: {:error, :missing_field}
  defp check_field(:error, _type), do: :ok

  defp check_field({:ok, value}, type) when type in [:required_string, :optional_string] do
    if is_binary(value), do: :ok, else: {:error, :field_type}
  end

  defp check_field({:ok, value}, :optional_integer) do
    if is_integer(value), do: :ok, else: {:error, :field_type}
  end

  defp check_field({:ok, value}, :optional_number) do
    if is_number(value), do: :ok, else: {:error, :field_type}
  end

  defp check_field({:ok, value}, :optional_boolean) do
    if is_boolean(value), do: :ok, else: {:error, :field_type}
  end
end
