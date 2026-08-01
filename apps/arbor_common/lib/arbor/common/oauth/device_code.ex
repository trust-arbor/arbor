defmodule Arbor.Common.OAuth.DeviceCode do
  @moduledoc """
  Provider-neutral RFC 8628 device-authorization primitives.

  The module intentionally owns only bounded transport and document parsing.
  Endpoint trust and policy stay in caller-specific layers (currently
  `Arbor.Security.OIDC`).
  """

  alias Arbor.Common.OAuth.AuthCode
  alias Arbor.Common.OAuth.HttpClient
  alias Arbor.Common.OAuth.HttpClient.{Request, Response}

  @default_max_response_bytes 65_536
  @default_timeout_ms 10_000
  @default_poll_timeout_ms 300_000
  @default_poll_interval 5

  @max_http_range 1_048_576
  @max_param_pairs 128
  @max_params 128
  @max_endpoint_bytes 2_048
  @max_client_id_bytes 2_048
  @max_client_secret_bytes 4_096
  @max_scope_bytes 128
  @max_scope_count 32
  @max_device_code_bytes 2_048
  @max_user_code_bytes 1_024
  @max_verification_uri_bytes 2_048
  @max_interval_seconds 3_600
  @min_interval_seconds 1
  @max_expires_in_seconds 86_400

  @max_token_string_bytes 8_192
  @max_token_map_keys 64
  @max_token_depth 4
  @max_token_key_bytes 128
  @default_token_response_schema %{
    "access_token" => :required_string,
    "token_type" => :required_string,
    "refresh_token" => :optional_string,
    "expires_in" => :optional_integer
  }

  @slow_down_increment 5

  defmodule StartParams do
    @moduledoc """
    Normalized, closed-key start arguments.
    """

    defstruct device_authorization_endpoint: nil,
              client_id: nil,
              client_secret: nil,
              scopes: nil,
              scope: nil,
              max_response_bytes: nil,
              timeout_ms: nil,
              allow_http: false,
              http_client: nil

    defimpl Inspect do
      import Inspect.Algebra

      @redacted [:device_authorization_endpoint, :client_secret]

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

        concat(["#Arbor.Common.OAuth.DeviceCode.StartParams<", to_doc(fields, opts), ">"])
      end
    end
  end

  defmodule PollParams do
    @moduledoc """
    Normalized, closed-key polling arguments.
    """

    defstruct token_endpoint: nil,
              client_id: nil,
              client_secret: nil,
              device_code: nil,
              response_schema: nil,
              interval: nil,
              expires_in: nil,
              poll_timeout_ms: nil,
              max_response_bytes: nil,
              timeout_ms: nil,
              allow_http: false,
              http_client: nil,
              now_fn: nil,
              sleep_fn: nil

    defimpl Inspect do
      import Inspect.Algebra

      @redacted [:token_endpoint, :device_code, :client_secret]

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

        concat(["#Arbor.Common.OAuth.DeviceCode.PollParams<", to_doc(fields, opts), ">"])
      end
    end
  end

  defmodule RefreshParams do
    @moduledoc """
    Normalized, closed-key refresh arguments.
    """

    defstruct token_endpoint: nil,
              client_id: nil,
              client_secret: nil,
              refresh_token: nil,
              response_schema: nil,
              max_response_bytes: nil,
              timeout_ms: nil,
              allow_http: false,
              http_client: nil

    defimpl Inspect do
      import Inspect.Algebra

      @redacted [:token_endpoint, :refresh_token, :client_secret]

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

        concat(["#Arbor.Common.OAuth.DeviceCode.RefreshParams<", to_doc(fields, opts), ">"])
      end
    end
  end

  @doc """
  Request a device authorization response from the already trusted `:device_authorization_endpoint`.
  """
  @spec start(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def start(opts) do
    with {:ok, params} <- normalize_start(opts),
         {:ok, request} <- build_start_request(params),
         {:ok, response} <- HttpClient.request(request, http_client: params.http_client),
         {:ok, token} <- parse_device_response(response) do
      {:ok, token}
    end
  end

  @doc """
  Poll the token endpoint until a terminal success/failure or an RFC 8628 terminal error.
  """
  @spec poll(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def poll(opts) do
    with {:ok, params} <- normalize_poll(opts) do
      deadline_ms =
        params.now_fn.() +
          min(params.poll_timeout_ms, params.expires_in * 1_000)

      poll_loop(params, deadline_ms)
    end
  end

  @doc """
  Refresh an access token using the token endpoint and validated arguments.
  """
  @spec refresh(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def refresh(opts) do
    with {:ok, params} <- normalize_refresh(opts),
         {:ok, request} <- build_refresh_request(params),
         {:ok, response} <- HttpClient.request(request, http_client: params.http_client),
         {:ok, token} <- parse_token_response(response, params.response_schema) do
      {:ok, token}
    end
  end

  @doc """
  Validate a response schema for token/documents without provider policy.
  """
  @spec validate_token_response_schema(term()) :: {:ok, map()} | {:error, term()}
  def validate_token_response_schema(schema), do: AuthCode.validate_response_schema(schema)

  # -- Polling ---------------------------------------------------------------

  defp poll_loop(%PollParams{} = params, deadline_ms) do
    now_ms = params.now_fn.()

    if now_ms >= deadline_ms do
      {:error, :device_flow_expired}
    else
      request_timeout_ms = min(params.timeout_ms, deadline_ms - now_ms)

      with {:ok, request} <- build_poll_request(params, request_timeout_ms),
           {:ok, response} <- HttpClient.request(request, http_client: params.http_client) do
        if params.now_fn.() >= deadline_ms do
          {:error, :device_flow_expired}
        else
          case response.status do
            200 ->
              parse_token_response(response, params.response_schema)

            400 ->
              handle_poll_rejection(response, params, deadline_ms)

            428 ->
              handle_poll_rejection(response, params, deadline_ms)

            status ->
              {:error, {:token_request_failed, status}}
          end
        end
      end
    end
  end

  defp handle_poll_rejection(response, params, deadline_ms) do
    case parse_poll_error(response.body) do
      :authorization_pending ->
        wait_before_poll(params, params.interval, deadline_ms)

      :slow_down ->
        updated = %{params | interval: poll_slow_down(params.interval)}
        wait_before_poll(updated, updated.interval, deadline_ms)

      :expired_token ->
        {:error, :device_code_expired}

      :access_denied ->
        {:error, :access_denied}

      :invalid_error_response ->
        {:error, {:token_request_failed, response.status}}
    end
  end

  defp wait_before_poll(params, interval, deadline_ms) do
    remaining_ms = deadline_ms - params.now_fn.()

    if remaining_ms <= 0 do
      {:error, :device_flow_expired}
    else
      params.sleep_fn.(min(interval * 1_000, remaining_ms))
      poll_loop(params, deadline_ms)
    end
  end

  defp poll_slow_down(interval),
    do: Enum.min([interval + @slow_down_increment, @max_interval_seconds])

  # -- Response parsing -------------------------------------------------------

  defp parse_device_response(%Response{status: 200, body: body}) do
    with {:ok, decoded} <- decode_json_map(body),
         :ok <- validate_response_shape(decoded),
         :ok <- validate_device_fields(decoded) do
      {:ok, Map.put_new(decoded, "interval", @default_poll_interval)}
    end
  end

  defp parse_device_response(%Response{status: status}),
    do: {:error, {:device_code_request_failed, status}}

  defp parse_token_response(%Response{status: 200, body: body}, schema) do
    with {:ok, decoded} <- decode_json_map(body),
         :ok <- validate_response_shape(decoded),
         :ok <- AuthCode.apply_response_schema(decoded, schema) do
      {:ok, decoded}
    end
  end

  defp parse_token_response(%Response{status: status, body: _body}, _schema),
    do: {:error, {:token_request_failed, status}}

  defp parse_poll_error(body) do
    with {:ok, decoded} <- decode_json_map(body),
         error when is_binary(error) <- Map.get(decoded, "error") do
      case error do
        "authorization_pending" -> :authorization_pending
        "slow_down" -> :slow_down
        "expired_token" -> :expired_token
        "access_denied" -> :access_denied
        _ -> :invalid_error_response
      end
    else
      _ -> :invalid_error_response
    end
  end

  defp validate_device_fields(decoded) do
    with :ok <- validate_required_string(decoded, "device_code", 1, @max_device_code_bytes),
         :ok <- validate_required_string(decoded, "user_code", 1, @max_user_code_bytes),
         :ok <-
           validate_required_string(decoded, "verification_uri", 1, @max_verification_uri_bytes),
         :ok <-
           validate_required_response_integer(decoded, "expires_in", 1, @max_expires_in_seconds),
         :ok <-
           validate_optional_response_integer(
             decoded,
             "interval",
             @min_interval_seconds,
             @max_interval_seconds
           ),
         :ok <- validate_optional_string(decoded, "verification_uri_complete", 1, 2_048) do
      :ok
    end
  end

  # -- Request builders -------------------------------------------------------

  defp build_start_request(%StartParams{} = params) do
    form =
      %{"client_id" => params.client_id}
      |> maybe_put_scopes(params.scope, params.scopes)
      |> maybe_put_secret(params.client_secret)

    {:ok,
     %Request{
       method: :post,
       url: params.device_authorization_endpoint,
       headers: [{"accept", "application/json"}],
       form: form,
       max_response_bytes: params.max_response_bytes,
       timeout_ms: params.timeout_ms
     }}
  end

  defp build_poll_request(%PollParams{} = params, timeout_ms) do
    form =
      %{
        "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
        "client_id" => params.client_id,
        "device_code" => params.device_code
      }
      |> maybe_put_secret(params.client_secret)

    {:ok,
     %Request{
       method: :post,
       url: params.token_endpoint,
       headers: [{"accept", "application/json"}],
       form: form,
       max_response_bytes: params.max_response_bytes,
       timeout_ms: timeout_ms
     }}
  end

  defp build_refresh_request(%RefreshParams{} = params) do
    form =
      %{
        "grant_type" => "refresh_token",
        "client_id" => params.client_id,
        "refresh_token" => params.refresh_token
      }
      |> maybe_put_secret(params.client_secret)

    {:ok,
     %Request{
       method: :post,
       url: params.token_endpoint,
       headers: [{"accept", "application/json"}],
       form: form,
       max_response_bytes: params.max_response_bytes,
       timeout_ms: params.timeout_ms
     }}
  end

  defp maybe_put_secret(form, nil), do: form
  defp maybe_put_secret(form, secret), do: Map.put(form, "client_secret", secret)

  defp maybe_put_scopes(form, scope, _scopes) when is_binary(scope),
    do: Map.put(form, "scope", scope)

  defp maybe_put_scopes(form, nil, scopes) when is_list(scopes) and scopes != [] do
    Map.put(form, "scope", Enum.join(scopes, " "))
  end

  defp maybe_put_scopes(form, _scope, _scopes), do: form

  # -- Normalization ----------------------------------------------------------

  defp normalize_start(opts) when is_list(opts),
    do: normalize_start_opts(opts, @max_param_pairs, %{})

  defp normalize_start(opts) when is_map(opts) and not is_struct(opts) do
    if map_size(opts) > @max_params do
      {:error, {:invalid_params, :too_many_params}}
    else
      normalize_start_opts(Map.to_list(opts), @max_param_pairs, %{})
    end
  end

  defp normalize_start(_opts), do: {:error, {:invalid_params, :keyword_or_map_required}}

  defp normalize_start_opts([], _remaining, acc) do
    params = %StartParams{
      device_authorization_endpoint: acc[:device_authorization_endpoint],
      client_id: acc[:client_id],
      client_secret: acc[:client_secret],
      scopes: acc[:scopes],
      scope: acc[:scope],
      max_response_bytes: Map.get(acc, :max_response_bytes, @default_max_response_bytes),
      timeout_ms: Map.get(acc, :timeout_ms, @default_timeout_ms),
      allow_http: Map.get(acc, :allow_http, false),
      http_client: acc[:http_client]
    }

    with :ok <- validate_common_request_params(params),
         :ok <- validate_required_text(:client_id, params.client_id, @max_client_id_bytes),
         :ok <-
           validate_optional_text(:client_secret, params.client_secret, @max_client_secret_bytes),
         :ok <- validate_scopes(params.scopes),
         :ok <- validate_scope(params.scope),
         :ok <- validate_scope_options(params.scope, params.scopes),
         :ok <- validate_endpoint(params.device_authorization_endpoint, params.allow_http) do
      {:ok, params}
    end
  end

  defp normalize_start_opts([{key, value} | rest], remaining, acc)
       when is_list(rest) do
    cond do
      remaining <= 0 ->
        {:error, {:invalid_params, :too_many_params}}

      true ->
        with {:ok, normalized_key} <- normalize_start_key(key),
             :ok <- duplicate_key_check(acc, normalized_key) do
          normalize_start_opts(rest, remaining - 1, Map.put(acc, normalized_key, value))
        end
    end
  end

  defp normalize_start_opts(_opts, _remaining, _acc),
    do: {:error, {:invalid_params, :invalid_option_term}}

  defp normalize_start_key(:device_authorization_endpoint),
    do: {:ok, :device_authorization_endpoint}

  defp normalize_start_key("device_authorization_endpoint"),
    do: {:ok, :device_authorization_endpoint}

  defp normalize_start_key(:client_id), do: {:ok, :client_id}
  defp normalize_start_key("client_id"), do: {:ok, :client_id}
  defp normalize_start_key(:client_secret), do: {:ok, :client_secret}
  defp normalize_start_key("client_secret"), do: {:ok, :client_secret}
  defp normalize_start_key(:scopes), do: {:ok, :scopes}
  defp normalize_start_key("scopes"), do: {:ok, :scopes}
  defp normalize_start_key(:scope), do: {:ok, :scope}
  defp normalize_start_key("scope"), do: {:ok, :scope}
  defp normalize_start_key(:max_response_bytes), do: {:ok, :max_response_bytes}
  defp normalize_start_key("max_response_bytes"), do: {:ok, :max_response_bytes}
  defp normalize_start_key(:timeout_ms), do: {:ok, :timeout_ms}
  defp normalize_start_key("timeout_ms"), do: {:ok, :timeout_ms}
  defp normalize_start_key(:allow_http), do: {:ok, :allow_http}
  defp normalize_start_key("allow_http"), do: {:ok, :allow_http}
  defp normalize_start_key(:http_client), do: {:ok, :http_client}
  defp normalize_start_key("http_client"), do: {:ok, :http_client}
  defp normalize_start_key(_), do: {:error, :unknown_key}

  defp normalize_poll(opts) when is_list(opts),
    do: normalize_poll_opts(opts, @max_param_pairs, %{})

  defp normalize_poll(opts) when is_map(opts) and not is_struct(opts) do
    if map_size(opts) > @max_params do
      {:error, {:invalid_params, :too_many_params}}
    else
      normalize_poll_opts(Map.to_list(opts), @max_param_pairs, %{})
    end
  end

  defp normalize_poll(_opts), do: {:error, {:invalid_params, :keyword_or_map_required}}

  defp normalize_poll_opts([], _remaining, acc) do
    params = %PollParams{
      token_endpoint: acc[:token_endpoint],
      client_id: acc[:client_id],
      client_secret: acc[:client_secret],
      device_code: acc[:device_code],
      response_schema: Map.get(acc, :response_schema, @default_token_response_schema),
      interval: Map.get(acc, :interval, @default_poll_interval),
      expires_in: acc[:expires_in],
      poll_timeout_ms: Map.get(acc, :poll_timeout_ms, @default_poll_timeout_ms),
      max_response_bytes: Map.get(acc, :max_response_bytes, @default_max_response_bytes),
      timeout_ms: Map.get(acc, :timeout_ms, @default_timeout_ms),
      allow_http: Map.get(acc, :allow_http, false),
      http_client: acc[:http_client],
      now_fn: Map.get(acc, :now_fn, &default_now/0),
      sleep_fn: Map.get(acc, :sleep_fn, &Process.sleep/1)
    }

    with :ok <- validate_common_request_params(params),
         :ok <- validate_required_text(:client_id, params.client_id, @max_client_id_bytes),
         :ok <- validate_required_text(:device_code, params.device_code, @max_device_code_bytes),
         :ok <-
           validate_required_integer(
             :interval,
             params.interval,
             @min_interval_seconds,
             @max_interval_seconds
           ),
         :ok <-
           validate_required_integer(:expires_in, params.expires_in, 1, @max_expires_in_seconds),
         :ok <-
           validate_required_integer(:poll_timeout_ms, params.poll_timeout_ms, 1, @max_http_range),
         :ok <- validate_endpoint(params.token_endpoint, params.allow_http),
         {:ok, _schema} <- AuthCode.validate_response_schema(params.response_schema),
         :ok <- validate_function(:now_fn, params.now_fn, 0),
         :ok <- validate_function(:sleep_fn, params.sleep_fn, 1) do
      {:ok, params}
    end
  end

  defp normalize_poll_opts([{key, value} | rest], remaining, acc)
       when is_list(rest) do
    cond do
      remaining <= 0 ->
        {:error, {:invalid_params, :too_many_params}}

      true ->
        with {:ok, normalized_key} <- normalize_poll_key(key),
             :ok <- duplicate_key_check(acc, normalized_key) do
          normalize_poll_opts(rest, remaining - 1, Map.put(acc, normalized_key, value))
        end
    end
  end

  defp normalize_poll_opts(_opts, _remaining, _acc),
    do: {:error, {:invalid_params, :invalid_option_term}}

  defp normalize_poll_key(:token_endpoint), do: {:ok, :token_endpoint}
  defp normalize_poll_key("token_endpoint"), do: {:ok, :token_endpoint}
  defp normalize_poll_key(:client_id), do: {:ok, :client_id}
  defp normalize_poll_key("client_id"), do: {:ok, :client_id}
  defp normalize_poll_key(:client_secret), do: {:ok, :client_secret}
  defp normalize_poll_key("client_secret"), do: {:ok, :client_secret}
  defp normalize_poll_key(:device_code), do: {:ok, :device_code}
  defp normalize_poll_key("device_code"), do: {:ok, :device_code}
  defp normalize_poll_key(:response_schema), do: {:ok, :response_schema}
  defp normalize_poll_key("response_schema"), do: {:ok, :response_schema}
  defp normalize_poll_key(:interval), do: {:ok, :interval}
  defp normalize_poll_key("interval"), do: {:ok, :interval}
  defp normalize_poll_key(:expires_in), do: {:ok, :expires_in}
  defp normalize_poll_key("expires_in"), do: {:ok, :expires_in}
  defp normalize_poll_key(:poll_timeout_ms), do: {:ok, :poll_timeout_ms}
  defp normalize_poll_key("poll_timeout_ms"), do: {:ok, :poll_timeout_ms}
  defp normalize_poll_key(:max_response_bytes), do: {:ok, :max_response_bytes}
  defp normalize_poll_key("max_response_bytes"), do: {:ok, :max_response_bytes}
  defp normalize_poll_key(:timeout_ms), do: {:ok, :timeout_ms}
  defp normalize_poll_key("timeout_ms"), do: {:ok, :timeout_ms}
  defp normalize_poll_key(:allow_http), do: {:ok, :allow_http}
  defp normalize_poll_key("allow_http"), do: {:ok, :allow_http}
  defp normalize_poll_key(:http_client), do: {:ok, :http_client}
  defp normalize_poll_key("http_client"), do: {:ok, :http_client}
  defp normalize_poll_key(:now_fn), do: {:ok, :now_fn}
  defp normalize_poll_key("now_fn"), do: {:ok, :now_fn}
  defp normalize_poll_key(:sleep_fn), do: {:ok, :sleep_fn}
  defp normalize_poll_key("sleep_fn"), do: {:ok, :sleep_fn}
  defp normalize_poll_key(_), do: {:error, :unknown_key}

  defp normalize_refresh(opts) when is_list(opts),
    do: normalize_refresh_opts(opts, @max_param_pairs, %{})

  defp normalize_refresh(opts) when is_map(opts) and not is_struct(opts) do
    if map_size(opts) > @max_params do
      {:error, {:invalid_params, :too_many_params}}
    else
      normalize_refresh_opts(Map.to_list(opts), @max_param_pairs, %{})
    end
  end

  defp normalize_refresh(_opts), do: {:error, {:invalid_params, :keyword_or_map_required}}

  defp normalize_refresh_opts([], _remaining, acc) do
    params = %RefreshParams{
      token_endpoint: acc[:token_endpoint],
      client_id: acc[:client_id],
      client_secret: acc[:client_secret],
      refresh_token: acc[:refresh_token],
      response_schema: Map.get(acc, :response_schema, @default_token_response_schema),
      max_response_bytes: Map.get(acc, :max_response_bytes, @default_max_response_bytes),
      timeout_ms: Map.get(acc, :timeout_ms, @default_timeout_ms),
      allow_http: Map.get(acc, :allow_http, false),
      http_client: acc[:http_client]
    }

    with :ok <- validate_common_request_params(params),
         :ok <- validate_required_text(:client_id, params.client_id, @max_client_id_bytes),
         :ok <-
           validate_required_text(:refresh_token, params.refresh_token, @max_token_string_bytes),
         :ok <- validate_endpoint(params.token_endpoint, params.allow_http),
         {:ok, _schema} <- AuthCode.validate_response_schema(params.response_schema) do
      {:ok, params}
    end
  end

  defp normalize_refresh_opts([{key, value} | rest], remaining, acc) when is_list(rest) do
    cond do
      remaining <= 0 ->
        {:error, {:invalid_params, :too_many_params}}

      true ->
        with {:ok, normalized_key} <- normalize_refresh_key(key),
             :ok <- duplicate_key_check(acc, normalized_key) do
          normalize_refresh_opts(rest, remaining - 1, Map.put(acc, normalized_key, value))
        end
    end
  end

  defp normalize_refresh_opts(_opts, _remaining, _acc),
    do: {:error, {:invalid_params, :invalid_option_term}}

  defp normalize_refresh_key(:token_endpoint), do: {:ok, :token_endpoint}
  defp normalize_refresh_key("token_endpoint"), do: {:ok, :token_endpoint}
  defp normalize_refresh_key(:client_id), do: {:ok, :client_id}
  defp normalize_refresh_key("client_id"), do: {:ok, :client_id}
  defp normalize_refresh_key(:client_secret), do: {:ok, :client_secret}
  defp normalize_refresh_key("client_secret"), do: {:ok, :client_secret}
  defp normalize_refresh_key(:refresh_token), do: {:ok, :refresh_token}
  defp normalize_refresh_key("refresh_token"), do: {:ok, :refresh_token}
  defp normalize_refresh_key(:response_schema), do: {:ok, :response_schema}
  defp normalize_refresh_key("response_schema"), do: {:ok, :response_schema}
  defp normalize_refresh_key(:max_response_bytes), do: {:ok, :max_response_bytes}
  defp normalize_refresh_key("max_response_bytes"), do: {:ok, :max_response_bytes}
  defp normalize_refresh_key(:timeout_ms), do: {:ok, :timeout_ms}
  defp normalize_refresh_key("timeout_ms"), do: {:ok, :timeout_ms}
  defp normalize_refresh_key(:allow_http), do: {:ok, :allow_http}
  defp normalize_refresh_key("allow_http"), do: {:ok, :allow_http}
  defp normalize_refresh_key(:http_client), do: {:ok, :http_client}
  defp normalize_refresh_key("http_client"), do: {:ok, :http_client}
  defp normalize_refresh_key(_), do: {:error, :unknown_key}

  # -- Validation -------------------------------------------------------------

  defp validate_common_request_params(%{allow_http: allow_http} = params) do
    with :ok <- validate_http_client(params),
         :ok <- validate_range(:max_response_bytes, params.max_response_bytes, @max_http_range),
         :ok <- validate_range(:timeout_ms, params.timeout_ms, HttpClient.max_timeout_ms()),
         :ok <- validate_allow_http(allow_http),
         :ok <-
           validate_optional_text(:client_secret, params.client_secret, @max_client_secret_bytes) do
      :ok
    end
  end

  defp validate_range(:max_response_bytes, nil, _max), do: {:error, {:invalid_params, :missing}}

  defp validate_range(:max_response_bytes, value, max)
       when is_integer(value) and value > 0 and value <= max, do: :ok

  defp validate_range(:max_response_bytes, _value, _max),
    do: {:error, {:invalid_params, {:max_response_bytes, :invalid_range}}}

  defp validate_range(:timeout_ms, nil, _max), do: {:error, {:invalid_params, :missing}}

  defp validate_range(:timeout_ms, value, max)
       when is_integer(value) and value > 0 and value <= max, do: :ok

  defp validate_range(:timeout_ms, _value, _max),
    do: {:error, {:invalid_params, {:timeout_ms, :invalid_range}}}

  defp validate_optional_text(:client_secret, nil, _max), do: :ok

  defp validate_optional_text(:client_secret, value, max),
    do: validate_text(:client_secret, value, max)

  defp validate_required_text(name, nil, _max), do: {:error, {:invalid_params, {name, :missing}}}

  defp validate_required_text(name, value, max), do: validate_text(name, value, max)

  defp validate_text(name, value, max) when is_binary(value) do
    if value != "" and byte_size(value) <= max and safe_text?(value) and
         not has_raw_whitespace?(value),
       do: :ok,
       else: {:error, {:invalid_params, {name, :invalid}}}
  end

  defp validate_text(_name, _value, _max), do: {:error, {:invalid_params, :invalid}}

  defp validate_scope(nil), do: :ok

  defp validate_scope(scope) when is_binary(scope) do
    if scope != "" and byte_size(scope) <= @max_scope_bytes and safe_text?(scope),
      do: :ok,
      else: {:error, {:invalid_params, :invalid_scopes}}
  end

  defp validate_scope(_scope), do: {:error, {:invalid_params, :invalid_scopes}}

  defp validate_scope_element(scope) when is_binary(scope) do
    if scope != "" and byte_size(scope) <= @max_scope_bytes and safe_text?(scope) and
         not has_raw_whitespace?(scope),
       do: :ok,
       else: {:error, {:invalid_params, :invalid_scopes}}
  end

  defp validate_scope_element(_scope), do: {:error, {:invalid_params, :invalid_scopes}}

  defp validate_scopes(nil), do: :ok

  defp validate_scopes(scopes) when is_list(scopes),
    do: validate_scopes(scopes, @max_scope_count)

  defp validate_scopes(_scopes), do: {:error, {:invalid_params, :invalid_scopes}}

  defp validate_scope_options(nil, _scopes), do: :ok
  defp validate_scope_options(_scope, nil), do: :ok
  defp validate_scope_options(_scope, _scopes), do: {:error, {:invalid_params, :scope_and_scopes}}

  defp validate_scopes([], _), do: :ok

  defp validate_scopes(_scopes, 0),
    do: {:error, {:invalid_params, :too_many_scopes}}

  defp validate_scopes([scope | rest], remaining) when remaining > 0 do
    with :ok <- validate_scope_element(scope) do
      validate_scopes(rest, remaining - 1)
    end
  end

  defp validate_scopes(_scopes, _remaining),
    do: {:error, {:invalid_params, :invalid_scopes}}

  defp validate_required_integer(name, nil, _min, _max),
    do: {:error, {:invalid_params, {name, :invalid_integer}}}

  defp validate_required_integer(_name, value, min, max)
       when is_integer(value) and value >= min and value <= max,
       do: :ok

  defp validate_required_integer(name, _value, _min, _max),
    do: {:error, {:invalid_params, {name, :invalid_integer}}}

  defp validate_optional_string(map, key, min, max) when is_map(map) do
    case Map.get(map, key) do
      nil ->
        :ok

      value when is_binary(value) ->
        if byte_size(value) >= min and byte_size(value) <= max and safe_text?(value),
          do: :ok,
          else: {:error, {:invalid_device_response, key}}

      _ ->
        {:error, {:invalid_device_response, key}}
    end
  end

  defp validate_required_string(map, key, min, max) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        if byte_size(value) >= min and byte_size(value) <= max and safe_text?(value),
          do: :ok,
          else: {:error, {:invalid_device_response, key}}

      _ ->
        {:error, {:invalid_device_response, key}}
    end
  end

  defp validate_required_response_integer(map, key, min, max) when is_map(map) do
    case Map.get(map, key) do
      value when is_integer(value) and value >= min and value <= max ->
        :ok

      _ ->
        {:error, {:invalid_device_response, key}}
    end
  end

  defp validate_optional_response_integer(map, key, min, max) when is_map(map) do
    case Map.fetch(map, key) do
      :error ->
        :ok

      {:ok, value} when is_integer(value) and value >= min and value <= max ->
        :ok

      _ ->
        {:error, {:invalid_device_response, key}}
    end
  end

  defp validate_allow_http(true), do: :ok
  defp validate_allow_http(false), do: :ok
  defp validate_allow_http(_), do: {:error, {:invalid_params, :invalid_allow_http}}

  defp validate_http_client(%{http_client: nil}), do: :ok

  defp validate_http_client(%{http_client: client}) when is_atom(client) do
    if Code.ensure_loaded?(client) and function_exported?(client, :request, 1),
      do: :ok,
      else: {:error, {:invalid_params, :invalid_http_client}}
  end

  defp validate_http_client(%{}), do: {:error, {:invalid_params, :invalid_http_client}}

  defp validate_endpoint(url, allow_http) when is_binary(url) do
    with true <- byte_size(url) > 0 and byte_size(url) <= @max_endpoint_bytes,
         true <- safe_text?(url),
         false <- has_raw_whitespace?(url),
         {:ok, uri} <- URI.new(url),
         :ok <- endpoint_scheme(uri, allow_http),
         :ok <- validate_host(uri.host),
         :ok <- endpoint_fragment(uri),
         :ok <- validate_port(uri) do
      :ok
    else
      _ -> {:error, {:invalid_params, :invalid_endpoint}}
    end
  end

  defp validate_endpoint(_url, _allow_http),
    do: {:error, {:invalid_params, :invalid_endpoint}}

  defp endpoint_scheme(%URI{scheme: "https"}, _allow_http), do: :ok
  defp endpoint_scheme(%URI{scheme: "http"}, true), do: :ok

  defp endpoint_scheme(%URI{scheme: "http"}, _allow_http),
    do: {:error, {:invalid_params, :invalid_scheme}}

  defp endpoint_scheme(_uri, _allow_http),
    do: {:error, {:invalid_params, :invalid_scheme}}

  defp endpoint_fragment(%URI{fragment: nil}), do: :ok
  defp endpoint_fragment(_uri), do: {:error, {:invalid_params, :invalid_endpoint}}

  defp validate_port(%URI{port: nil}), do: :ok
  defp validate_port(%URI{port: port}) when is_integer(port) and port in 1..65_535, do: :ok
  defp validate_port(_uri), do: {:error, {:invalid_params, :invalid_port}}

  defp validate_host(host) when is_binary(host) and host != "" do
    normalized = normalize_ipv6_host(host)

    if valid_host?(normalized) do
      :ok
    else
      {:error, {:invalid_params, :invalid_host}}
    end
  end

  defp validate_host(_host), do: {:error, {:invalid_params, :invalid_host}}

  defp valid_host?(host) do
    cond do
      String.contains?(host, ":") ->
        case :inet.parse_address(String.to_charlist(host)) do
          {:ok, _} -> true
          {:error, _} -> false
        end

      true ->
        Regex.match?(
          ~r/\A(?:[A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]*[A-Za-z0-9])(?:\.(?:[A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]*[A-Za-z0-9]))*\z/,
          host
        )
    end
  end

  defp normalize_ipv6_host(host) do
    cond do
      String.starts_with?(host, "[") and String.ends_with?(host, "]") ->
        String.slice(host, 1, byte_size(host) - 2)

      true ->
        host
    end
  end

  defp decode_json_map(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _} -> {:error, {:invalid_token_response, :object_required}}
      {:error, _} -> {:error, {:invalid_token_response, :malformed_json}}
    end
  end

  defp decode_json_map(_body), do: {:error, {:invalid_token_response, :malformed_json}}

  # -- Shape bounds -----------------------------------------------------------

  defp validate_response_shape(decoded) do
    response_shape(decoded, 0)
  end

  defp response_shape(_term, depth) when depth > @max_token_depth,
    do: {:error, {:invalid_token_response, :depth}}

  defp response_shape(term, _depth)
       when is_binary(term) and byte_size(term) > @max_token_string_bytes,
       do: {:error, {:invalid_token_response, :value_bytes}}

  defp response_shape(term, _depth) when is_number(term) or is_boolean(term), do: :ok

  defp response_shape(term, depth) when is_list(term) do
    if length(term) > @max_token_map_keys do
      {:error, {:invalid_token_response, :list_items}}
    else
      Enum.reduce_while(term, :ok, fn item, _acc ->
        case response_shape(item, depth + 1) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp response_shape(map, depth) when is_map(map) do
    if map_size(map) > @max_token_map_keys do
      {:error, {:invalid_token_response, :keys}}
    else
      Enum.reduce_while(map, :ok, fn {key, value}, _acc ->
        cond do
          valid_shape_key(key) and validate_token_key(key) ->
            case response_shape(value, depth + 1) do
              :ok -> {:cont, :ok}
              {:error, _reason} = error -> {:halt, error}
            end

          true ->
            {:halt, {:error, {:invalid_token_response, :invalid_key}}}
        end
      end)
    end
  end

  defp response_shape(%{}, _depth), do: :ok
  defp response_shape(_other, _depth), do: :ok

  defp valid_shape_key(key) when is_binary(key), do: safe_text?(key)
  defp valid_shape_key(_), do: false

  defp validate_token_key(key) when is_binary(key) and byte_size(key) <= @max_token_key_bytes,
    do: true

  defp validate_token_key(_), do: false

  # -- Shared helpers ---------------------------------------------------------

  defp duplicate_key_check(map, key) do
    if Map.has_key?(map, key), do: {:error, :duplicate_key}, else: :ok
  end

  defp safe_text?(text) when is_binary(text) do
    String.valid?(text) and Enum.all?(:binary.bin_to_list(text), &(&1 >= 0x20 and &1 != 0x7F))
  end

  defp safe_text?(_text), do: false

  defp has_raw_whitespace?(text) when is_binary(text) do
    String.match?(text, ~r/\s/u)
  end

  defp default_now, do: System.monotonic_time(:millisecond)

  defp validate_function(_name, fun, arity) when is_function(fun, arity), do: :ok
  defp validate_function(name, _fun, _arity), do: {:error, {:invalid_params, {name, :invalid_fn}}}
end
