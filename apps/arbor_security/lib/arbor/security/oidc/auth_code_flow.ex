defmodule Arbor.Security.OIDC.AuthCodeFlow do
  @moduledoc """
  OIDC Authorization Code + PKCE flow for browser-based authentication.

  This remains a thin composition:

    * `Arbor.Security.OIDC.Discovery` for endpoint trust decisions.
    * `Arbor.Common.OAuth.AuthCode` for bounded protocol transport and decoding.
  """

  alias Arbor.Common.OAuth.AuthCode
  alias Arbor.Security.OIDC.Discovery

  require Logger

  @default_scopes ["openid", "email", "profile"]

  @token_response_schema %{
    "id_token" => :required_string,
    "access_token" => :optional_string,
    "token_type" => :optional_string,
    "refresh_token" => :optional_string,
    "scope" => :optional_string,
    "expires_in" => :optional_integer
  }

  @token_max_response_bytes 65_536
  @token_timeout_ms 10_000

  @max_provider_fields 128

  @max_issuer_bytes 2_048
  @max_client_id_bytes 2_048
  @max_client_secret_bytes 4_096
  @max_redirect_uri_bytes 2_048
  @max_state_bytes 1_024
  @max_code_bytes 1_024
  @max_code_verifier_bytes 1_024
  @max_code_challenge_bytes 1_024

  @max_scopes 32
  @max_scope_bytes 128

  @doc """
  Generate a PKCE code verifier and code challenge.
  """
  @spec generate_pkce() :: {String.t(), String.t()}
  defdelegate generate_pkce(), to: AuthCode

  @doc """
  Generate a cryptographic random state parameter for CSRF protection.
  """
  @spec generate_state() :: String.t()
  defdelegate generate_state(), to: AuthCode

  @doc """
  Build the OIDC authorization URL with PKCE parameters.
  """
  @spec build_authorize_url(term(), String.t(), String.t(), term()) ::
          {:ok, String.t(), String.t()} | {:error, term()}
  def build_authorize_url(provider, redirect_uri, state, opts \\ []) do
    with {:ok, provider} <- normalize_provider_input(provider),
         {:ok, normalized_opts} <- normalize_option_input(opts),
         :ok <- validate_uri_text(:issuer, provider_get(provider, :issuer), @max_issuer_bytes),
         :ok <-
           validate_text(:client_id, provider_get(provider, :client_id), @max_client_id_bytes),
         :ok <- validate_uri_text(:redirect_uri, redirect_uri, @max_redirect_uri_bytes),
         :ok <- validate_text(:state, state, @max_state_bytes),
         :ok <-
           validate_code_challenge_method(
             option_get(normalized_opts, :code_challenge_method, "S256")
           ),
         :ok <- validate_allow_http(provider_get(provider, :allow_http)),
         :ok <-
           validate_scopes(
             option_get(
               normalized_opts,
               :scopes,
               provider_get(provider, :scopes, @default_scopes)
             )
           ),
         :ok <-
           validate_code_challenge_fields(
             option_get(normalized_opts, :code_challenge, nil),
             option_get(normalized_opts, :code_verifier, nil)
           ),
         {:ok, {code_verifier, code_challenge}} <-
           build_code_pair(
             option_get(normalized_opts, :code_challenge, nil),
             option_get(normalized_opts, :code_verifier, nil)
           ),
         {:ok, extra_query} <-
           AuthCode.validate_extra_query(option_get(normalized_opts, :extra_query, [])),
         {:ok, endpoints} <- discover(provider, :authorize),
         {:ok, endpoint} <-
           require_endpoint(endpoints.authorization_endpoint, :no_authorization_endpoint),
         {:ok, url} <-
           AuthCode.build_authorize_url(
             authorization_endpoint: endpoint,
             client_id: provider_get(provider, :client_id),
             redirect_uri: redirect_uri,
             state: state,
             scopes:
               option_get(
                 normalized_opts,
                 :scopes,
                 provider_get(provider, :scopes, @default_scopes)
               ),
             code_challenge: code_challenge,
             code_challenge_method: option_get(normalized_opts, :code_challenge_method, "S256"),
             extra_query: extra_query,
             allow_http: allow_http?(provider),
             http_client: provider_get(provider, :http_client)
           ) do
      {:ok, url, code_verifier}
    else
      {:error, reason} ->
        Logger.debug("[OIDC.AuthCodeFlow] authorize URL rejected: #{inspect(reason)}")
        {:error, normalize_error(reason)}
    end
  end

  @doc """
  Exchange an authorization code for tokens.
  """
  @spec exchange_code(term(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def exchange_code(provider, code, redirect_uri, code_verifier) do
    with {:ok, provider} <- normalize_provider_input(provider),
         :ok <- validate_uri_text(:issuer, provider_get(provider, :issuer), @max_issuer_bytes),
         :ok <-
           validate_text(:client_id, provider_get(provider, :client_id), @max_client_id_bytes),
         :ok <- validate_uri_text(:redirect_uri, redirect_uri, @max_redirect_uri_bytes),
         :ok <- validate_text(:code, code, @max_code_bytes),
         :ok <- validate_code_verifier(code_verifier),
         :ok <-
           validate_optional_text(
             :client_secret,
             provider_get(provider, :client_secret),
             @max_client_secret_bytes
           ),
         :ok <- validate_allow_http(provider_get(provider, :allow_http)),
         :ok <- validate_http_client(provider_get(provider, :http_client)),
         {:ok, response_schema} <-
           AuthCode.validate_response_schema(
             Map.get(provider, :response_schema, @token_response_schema)
           ),
         :ok <-
           validate_numeric_option(
             :max_response_bytes,
             provider_get(provider, :max_response_bytes),
             @token_max_response_bytes
           ),
         :ok <-
           validate_numeric_option(
             :timeout_ms,
             provider_get(provider, :timeout_ms),
             @token_timeout_ms
           ),
         {:ok, endpoints} <- discover(provider, :token),
         {:ok, endpoint} <- require_endpoint(endpoints.token_endpoint, :no_token_endpoint),
         {:ok, tokens} <-
           AuthCode.exchange_code(
             token_endpoint: endpoint,
             client_id: provider_get(provider, :client_id),
             client_secret: provider_get(provider, :client_secret),
             code: code,
             redirect_uri: redirect_uri,
             code_verifier: code_verifier,
             response_schema: response_schema,
             max_response_bytes:
               provider_get(provider, :max_response_bytes, @token_max_response_bytes),
             timeout_ms: provider_get(provider, :timeout_ms, @token_timeout_ms),
             allow_http: allow_http?(provider),
             http_client: provider_get(provider, :http_client)
           ) do
      {:ok, tokens}
    else
      {:error, reason} ->
        Logger.debug("[OIDC.AuthCodeFlow] token exchange failed: #{inspect(reason)}")
        {:error, normalize_error(reason)}
    end
  end

  # --- Private ---

  defp discover(provider, operation) do
    opts =
      %{
        allow_http: provider_get(provider, :allow_http, false),
        endpoints: provider_get(provider, :endpoints),
        trusted_origins: provider_get(provider, :trusted_origins, []),
        http_client: provider_get(provider, :http_client),
        for: operation
      }
      |> maybe_put(:timeout_ms, provider_get(provider, :timeout_ms))
      |> maybe_put(:max_response_bytes, provider_get(provider, :discovery_max_response_bytes))

    Discovery.discover(provider_get(provider, :issuer), opts)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Map.put(opts, key, value)

  defp allow_http?(provider), do: provider_get(provider, :allow_http, false)

  defp require_endpoint(endpoint, _reason) when is_binary(endpoint) and endpoint != "",
    do: {:ok, endpoint}

  defp require_endpoint(_endpoint, reason), do: {:error, reason}

  defp normalize_error({:timeout, _ms} = reason), do: {:http_request_failed, reason}
  defp normalize_error({:transport_error, _reason} = reason), do: {:http_request_failed, reason}
  defp normalize_error(reason), do: reason

  defp normalize_provider_input(provider) when is_map(provider) and not is_struct(provider) do
    if map_size(provider) > @max_provider_fields do
      {:error, {:invalid_provider, :too_many_fields}}
    else
      normalize_input_items(Map.to_list(provider), :provider, @max_provider_fields, %{})
    end
  end

  defp normalize_provider_input(_provider), do: {:error, {:invalid_provider, :invalid_map}}

  defp normalize_option_input(opts) when is_map(opts) and not is_struct(opts) do
    if map_size(opts) > @max_provider_fields do
      {:error, {:invalid_params, :too_many_options}}
    else
      normalize_input_items(Map.to_list(opts), :option, @max_provider_fields, %{})
    end
  end

  defp normalize_option_input(opts) when is_list(opts) do
    with :ok <- validate_option_list_bound(opts, @max_provider_fields) do
      normalize_input_items(opts, :option, @max_provider_fields, %{})
    end
  end

  defp normalize_option_input(_opts), do: {:error, {:invalid_params, :invalid_options}}

  defp validate_option_list_bound([], _remaining), do: :ok

  defp validate_option_list_bound(_items, remaining) when remaining <= 0,
    do: {:error, {:invalid_params, :too_many_options}}

  defp validate_option_list_bound([_item | rest], remaining),
    do: validate_option_list_bound(rest, remaining - 1)

  defp validate_option_list_bound(_improper, _remaining),
    do: {:error, {:invalid_params, :invalid_options}}

  defp normalize_input_items([], _kind, _remaining, acc), do: {:ok, acc}

  defp normalize_input_items(_pairs, :provider, remaining, _acc)
       when is_integer(remaining) and remaining <= 0,
       do: {:error, {:invalid_provider, :too_many_fields}}

  defp normalize_input_items(_pairs, :option, remaining, _acc)
       when is_integer(remaining) and remaining <= 0,
       do: {:error, {:invalid_params, :too_many_options}}

  defp normalize_input_items([{key, value} | rest], :provider, remaining, acc)
       when is_list(rest) do
    with {:ok, normalized_key} <- normalize_provider_key(key),
         :ok <- check_duplicate(acc, :provider, normalized_key) do
      normalize_input_items(rest, :provider, remaining - 1, Map.put(acc, normalized_key, value))
    else
      {:error, :duplicate_key} -> {:error, {:invalid_provider, :duplicate_key}}
      {:error, :unknown_key} -> {:error, {:invalid_provider, :unknown_key}}
    end
  end

  defp normalize_input_items([{key, value} | rest], :option, remaining, acc) when is_list(rest) do
    with {:ok, normalized_key} <- normalize_option_key(key),
         :ok <- check_duplicate(acc, :option, normalized_key) do
      normalize_input_items(rest, :option, remaining - 1, Map.put(acc, normalized_key, value))
    else
      {:error, :duplicate_key} -> {:error, {:invalid_params, :duplicate_key}}
      {:error, :unknown_key} -> {:error, {:invalid_params, :unknown_key}}
    end
  end

  defp normalize_input_items(_items, :provider, _remaining, _acc),
    do: {:error, {:invalid_provider, :invalid_map}}

  defp normalize_input_items(_items, :option, _remaining, _acc),
    do: {:error, {:invalid_params, :invalid_options}}

  defp normalize_provider_key(:issuer), do: {:ok, :issuer}
  defp normalize_provider_key("issuer"), do: {:ok, :issuer}
  defp normalize_provider_key(:client_id), do: {:ok, :client_id}
  defp normalize_provider_key("client_id"), do: {:ok, :client_id}
  defp normalize_provider_key(:client_secret), do: {:ok, :client_secret}
  defp normalize_provider_key("client_secret"), do: {:ok, :client_secret}
  defp normalize_provider_key(:scopes), do: {:ok, :scopes}
  defp normalize_provider_key("scopes"), do: {:ok, :scopes}
  defp normalize_provider_key(:response_schema), do: {:ok, :response_schema}
  defp normalize_provider_key("response_schema"), do: {:ok, :response_schema}
  defp normalize_provider_key(:allow_http), do: {:ok, :allow_http}
  defp normalize_provider_key("allow_http"), do: {:ok, :allow_http}
  defp normalize_provider_key(:trusted_origins), do: {:ok, :trusted_origins}
  defp normalize_provider_key("trusted_origins"), do: {:ok, :trusted_origins}
  defp normalize_provider_key(:endpoints), do: {:ok, :endpoints}
  defp normalize_provider_key("endpoints"), do: {:ok, :endpoints}
  defp normalize_provider_key(:http_client), do: {:ok, :http_client}
  defp normalize_provider_key("http_client"), do: {:ok, :http_client}

  defp normalize_provider_key(:discovery_max_response_bytes),
    do: {:ok, :discovery_max_response_bytes}

  defp normalize_provider_key("discovery_max_response_bytes"),
    do: {:ok, :discovery_max_response_bytes}

  defp normalize_provider_key(:max_response_bytes), do: {:ok, :max_response_bytes}
  defp normalize_provider_key("max_response_bytes"), do: {:ok, :max_response_bytes}
  defp normalize_provider_key(:timeout_ms), do: {:ok, :timeout_ms}
  defp normalize_provider_key("timeout_ms"), do: {:ok, :timeout_ms}
  defp normalize_provider_key(_), do: {:error, :unknown_key}

  defp normalize_option_key(:code_challenge), do: {:ok, :code_challenge}
  defp normalize_option_key("code_challenge"), do: {:ok, :code_challenge}
  defp normalize_option_key(:code_verifier), do: {:ok, :code_verifier}
  defp normalize_option_key("code_verifier"), do: {:ok, :code_verifier}
  defp normalize_option_key(:code_challenge_method), do: {:ok, :code_challenge_method}
  defp normalize_option_key("code_challenge_method"), do: {:ok, :code_challenge_method}
  defp normalize_option_key(:scopes), do: {:ok, :scopes}
  defp normalize_option_key("scopes"), do: {:ok, :scopes}
  defp normalize_option_key(:extra_query), do: {:ok, :extra_query}
  defp normalize_option_key("extra_query"), do: {:ok, :extra_query}
  defp normalize_option_key(_), do: {:error, :unknown_key}

  defp check_duplicate(map, _kind, canonical_key) do
    if Map.has_key?(map, canonical_key),
      do: {:error, :duplicate_key},
      else: :ok
  end

  defp provider_get(provider, key, default \\ nil), do: Map.get(provider, key, default)
  defp option_get(opts, key, default), do: Map.get(opts, key, default)

  defp validate_allow_http(value) when value in [nil, true, false], do: :ok
  defp validate_allow_http(_value), do: {:error, {:invalid_params, :invalid_allow_http}}

  defp validate_http_client(nil), do: :ok

  defp validate_http_client(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :request, 1),
      do: :ok,
      else: {:error, {:invalid_params, :invalid_http_client}}
  end

  defp validate_http_client(_other), do: {:error, {:invalid_params, :invalid_http_client}}

  defp validate_text(_field, value, max) when is_binary(value) do
    if value != "" and byte_size(value) <= max and safe_text?(value),
      do: :ok,
      else: {:error, {:invalid_params, :invalid_text}}
  end

  defp validate_text(_field, _value, _max), do: {:error, {:invalid_params, :invalid_text}}

  defp validate_uri_text(field, value, max) do
    with :ok <- validate_text(field, value, max) do
      if has_raw_whitespace?(value),
        do: {:error, {:invalid_params, :invalid_text}},
        else: :ok
    end
  end

  defp validate_optional_text(_field, nil, _max), do: :ok
  defp validate_optional_text(field, value, max), do: validate_text(field, value, max)

  defp validate_numeric_option(_field, nil, _max), do: :ok

  defp validate_numeric_option(field, value, max) do
    if is_integer(value) and value > 0 and value <= max do
      :ok
    else
      {:error, {:invalid_params, {field, :invalid_range}}}
    end
  end

  defp validate_scopes(scopes) when scopes in [nil, []], do: :ok
  defp validate_scopes(scopes) when is_list(scopes), do: validate_scopes(scopes, @max_scopes)
  defp validate_scopes(_scopes), do: {:error, {:invalid_params, :invalid_scopes}}

  defp validate_scopes([], _remaining), do: :ok

  defp validate_scopes(_scopes, remaining) when remaining <= 0,
    do: {:error, {:invalid_params, :too_many_scopes}}

  defp validate_scopes([scope | rest], remaining) when is_list(rest) do
    with :ok <- validate_scope(scope),
         :ok <- validate_scopes(rest, remaining - 1) do
      :ok
    end
  end

  defp validate_scopes(_scopes, _remaining), do: {:error, {:invalid_params, :invalid_scopes}}

  defp validate_scope(scope) when is_binary(scope) do
    cond do
      scope == "" -> {:error, {:invalid_params, :invalid_scopes}}
      byte_size(scope) > @max_scope_bytes -> {:error, {:invalid_params, :invalid_scopes}}
      not safe_text?(scope) -> {:error, {:invalid_params, :invalid_scopes}}
      has_raw_whitespace?(scope) -> {:error, {:invalid_params, :invalid_scopes}}
      true -> :ok
    end
  end

  defp validate_scope(_scope), do: {:error, {:invalid_params, :invalid_scopes}}

  defp validate_code_challenge_method("S256"), do: :ok

  defp validate_code_challenge_method(_),
    do: {:error, {:invalid_params, :invalid_challenge_method}}

  defp validate_code_challenge_fields(nil, nil), do: :ok

  defp validate_code_challenge_fields(challenge, code_verifier)
       when is_binary(challenge) and code_verifier in [nil, ""] do
    validate_text(:code_challenge, challenge, @max_code_challenge_bytes)
  end

  defp validate_code_challenge_fields(challenge, code_verifier)
       when is_binary(challenge) and is_binary(code_verifier) and code_verifier != "" do
    with :ok <- validate_text(:code_challenge, challenge, @max_code_challenge_bytes),
         :ok <- validate_text(:code_verifier, code_verifier, @max_code_verifier_bytes) do
      :ok
    end
  end

  defp validate_code_challenge_fields(_challenge, _verifier),
    do: {:error, {:invalid_params, :invalid_code_challenge_pair}}

  defp validate_code_verifier(""), do: :ok

  defp validate_code_verifier(value),
    do: validate_text(:code_verifier, value, @max_code_verifier_bytes)

  defp build_code_pair(nil, nil), do: {:ok, generate_pkce()}
  defp build_code_pair(nil, _), do: {:error, {:invalid_params, :invalid_code_challenge_pair}}

  defp build_code_pair(challenge, nil) when is_binary(challenge) do
    with :ok <- validate_text(:code_challenge, challenge, @max_code_challenge_bytes) do
      {:ok, {"", challenge}}
    end
  end

  defp build_code_pair(challenge, "") when is_binary(challenge) do
    with :ok <- validate_text(:code_challenge, challenge, @max_code_challenge_bytes) do
      {:ok, {"", challenge}}
    end
  end

  defp build_code_pair(challenge, code_verifier)
       when is_binary(challenge) and is_binary(code_verifier) do
    with :ok <- validate_text(:code_challenge, challenge, @max_code_challenge_bytes),
         :ok <- validate_text(:code_verifier, code_verifier, @max_code_verifier_bytes) do
      {:ok, {code_verifier, challenge}}
    end
  end

  defp build_code_pair(_challenge, _code_verifier),
    do: {:error, {:invalid_params, :invalid_code_challenge_pair}}

  defp safe_text?(text) do
    String.valid?(text) and Enum.all?(:binary.bin_to_list(text), &(&1 >= 0x20 and &1 != 0x7F))
  end

  defp has_raw_whitespace?(text), do: String.match?(text, ~r/\s/u)
end
