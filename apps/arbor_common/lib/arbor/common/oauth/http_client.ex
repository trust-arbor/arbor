defmodule Arbor.Common.OAuth.HttpClient do
  @moduledoc """
  Domain-scoped HTTP seam for the OAuth acquisition boundary.

  This is deliberately **not** a general-purpose HTTP facade. It exists only to
  serve `Arbor.Common.OAuth.AuthCode` and the provider-owning callers layered
  above it (currently `Arbor.Security.OIDC`). Keeping the namespace narrow is
  what makes the OAuth-correct defaults defensible:

    * `retry: false` — an authorization code is single-use; a transparent retry
      re-POSTs a spent code and produces a spurious `invalid_grant`.
    * Small byte budgets — token and discovery documents are kilobytes.
    * Identity content-encoding only — a byte bound that is applied to
      compressed bytes is not a bound on memory.

  Those are wrong as global HTTP defaults, which is why this does not live at
  `Arbor.Common.HttpClient`.

  ## Adapter resolution

  Callers may pass `:http_client` explicitly. Otherwise the adapter comes from
  application config, defaulting to the bundled `Req` adapter:

      config :arbor_common, :oauth_http_client, Arbor.Common.OAuth.HttpClient.Req

  ## Error vocabulary

  Adapters MUST normalize failures into this closed set. No transport internals,
  no response body material, no credential material:

    * `{:timeout, timeout_ms}`
    * `{:transport_error, :econnrefused | :nxdomain | :closed | :other}`
    * `{:response_bytes_exceeded, max_response_bytes}`
    * `{:invalid_response, :non_identity_content_encoding | :invalid_headers}`
    * `{:invalid_request, reason}` where `reason` is one of this facade's
      closed validation reasons
  """

  alias Arbor.Common.OAuth.HttpClient.{Request, Response}

  @default_adapter Arbor.Common.OAuth.HttpClient.Req
  @max_response_bytes 1_048_576
  @max_timeout_ms 120_000
  @max_request_headers 64
  @max_request_options 16
  @max_request_header_name_bytes 256
  @max_request_header_value_bytes 4_096
  @max_response_headers 64
  @max_response_header_name_bytes 256
  @max_response_header_value_bytes 4_096
  @max_response_header_bytes 32_768
  @allowed_request_option_keys [:http_client]
  @transport_errors [:econnrefused, :nxdomain, :closed, :other]
  @invalid_request_atoms [
    :unsupported_method,
    :url_required,
    :headers_must_be_list,
    :invalid_headers,
    :form_must_be_map,
    :invalid_options,
    :invalid_http_client
  ]

  @typedoc "Normalized, body-free failure reasons."
  @type error ::
          {:timeout, pos_integer()}
          | {:transport_error, :econnrefused | :nxdomain | :closed | :other}
          | {:response_bytes_exceeded, pos_integer()}
          | {:invalid_response, :non_identity_content_encoding | :invalid_headers}
          | {:invalid_request, term()}

  @callback request(Request.t()) :: {:ok, Response.t()} | {:error, error()}

  defmodule Request do
    @moduledoc """
    A bounded OAuth HTTP request.

    `:form` is `application/x-www-form-urlencoded` body data (token requests);
    `nil` for GET.
    """

    @enforce_keys [:method, :url, :max_response_bytes, :timeout_ms]
    defstruct method: :get,
              url: nil,
              headers: [],
              form: nil,
              max_response_bytes: nil,
              timeout_ms: nil

    @type t :: %__MODULE__{
            method: :get | :post,
            url: String.t(),
            headers: [{String.t(), String.t()}],
            form: map() | nil,
            max_response_bytes: pos_integer(),
            timeout_ms: pos_integer()
          }

    defimpl Inspect do
      import Inspect.Algebra

      def inspect(request, opts) do
        fields =
          request
          |> Map.from_struct()
          |> Map.update!(:headers, &redact_headers/1)
          |> Map.update!(:form, fn
            nil -> nil
            _form -> "[REDACTED]"
          end)
          |> Enum.sort()

        concat(["#Arbor.Common.OAuth.HttpClient.Request<", to_doc(fields, opts), ">"])
      end

      defp redact_headers([]), do: []

      defp redact_headers(headers) when is_list(headers) do
        Enum.map(headers, fn
          {name, _value} -> {name, "[REDACTED]"}
          _other -> "[REDACTED]"
        end)
      end

      defp redact_headers(_headers), do: "[REDACTED]"
    end
  end

  defmodule Response do
    @moduledoc """
    A bounded OAuth HTTP response.

    `:body` is the **raw** response binary — never decoded, never decompressed,
    and never larger than the request's `max_response_bytes`. Decoding is the
    caller's job so that structural budgets stay caller-owned.
    """

    @enforce_keys [:status, :body]
    defstruct status: nil, headers: [], body: ""

    @type t :: %__MODULE__{
            status: non_neg_integer(),
            headers: [{String.t(), String.t()}],
            body: binary()
          }

    defimpl Inspect do
      import Inspect.Algebra

      def inspect(response, opts) do
        fields =
          response
          |> Map.from_struct()
          |> Map.update!(:headers, &redact_headers/1)
          |> Map.update!(:body, fn
            "" -> ""
            _body -> "[REDACTED]"
          end)
          |> Enum.sort()

        concat(["#Arbor.Common.OAuth.HttpClient.Response<", to_doc(fields, opts), ">"])
      end

      defp redact_headers([]), do: []

      defp redact_headers(headers) when is_list(headers) do
        Enum.map(headers, fn
          {name, _value} -> {name, "[REDACTED]"}
          _other -> "[REDACTED]"
        end)
      end

      defp redact_headers(_headers), do: "[REDACTED]"
    end
  end

  @doc """
  Perform a bounded OAuth HTTP request through the configured adapter.

  ## Options

    * `:http_client` — adapter module override (defaults to app config, then
      `Arbor.Common.OAuth.HttpClient.Req`)
  """
  @spec request(Request.t(), keyword()) :: {:ok, Response.t()} | {:error, error()}
  def request(%Request{} = request, opts \\ []) do
    with {:ok, normalized_opts} <- normalize_opts(opts),
         {:ok, adapter} <- resolve_adapter(normalized_opts),
         :ok <- validate(request) do
      call_adapter(adapter, request)
    end
  end

  @doc "Resolve the adapter module for the given options."
  @spec adapter(keyword()) :: module()
  def adapter(opts \\ []) do
    case normalize_opts(opts) do
      {:ok, normalized_opts} ->
        case resolve_adapter(normalized_opts) do
          {:ok, module} -> module
          {:error, _reason} -> @default_adapter
        end

      {:error, _reason} ->
        @default_adapter
    end
  end

  defp normalize_opts(opts) do
    if is_list(opts) do
      case validate_keyword_list(opts, @max_request_options, MapSet.new()) do
        :ok -> {:ok, opts}
        {:error, _reason} -> {:error, {:invalid_request, :invalid_options}}
      end
    else
      {:error, {:invalid_request, :invalid_options}}
    end
  end

  defp validate_keyword_list([], _remaining, _seen), do: :ok

  defp validate_keyword_list(_opts, remaining, _seen) when remaining <= 0,
    do: {:error, :too_many_entries}

  defp validate_keyword_list([{key, _value} | rest], remaining, seen)
       when is_list(rest) and is_atom(key) do
    if key in seen or key not in @allowed_request_option_keys do
      {:error, :invalid_keywords}
    else
      validate_keyword_list(rest, remaining - 1, MapSet.put(seen, key))
    end
  end

  defp validate_keyword_list(_opts, _remaining, _seen),
    do: {:error, :invalid_keyword_list}

  @doc false
  defp resolve_adapter(opts) do
    case Keyword.get(opts, :http_client) do
      nil ->
        adapter_from_config()

      module when is_atom(module) ->
        if Code.ensure_loaded?(module) and function_exported?(module, :request, 1) do
          {:ok, module}
        else
          {:error, {:invalid_request, :invalid_http_client}}
        end

      _other ->
        {:error, {:invalid_request, :invalid_http_client}}
    end
  end

  defp adapter_from_config do
    case Application.get_env(:arbor_common, :oauth_http_client, @default_adapter) do
      module when is_atom(module) ->
        if Code.ensure_loaded?(module) and function_exported?(module, :request, 1) do
          {:ok, module}
        else
          {:error, {:invalid_request, :invalid_http_client}}
        end

      _other ->
        {:error, {:invalid_request, :invalid_http_client}}
    end
  end

  @doc "The adapter used when neither options nor config specify one."
  @spec default_adapter() :: module()
  def default_adapter, do: @default_adapter

  defp call_adapter(adapter, request) do
    result =
      try do
        adapter.request(request)
      rescue
        _exception -> :invalid_adapter_result
      catch
        _kind, _reason -> :invalid_adapter_result
      end

    normalize_adapter_result(result, request)
  end

  defp normalize_adapter_result(
         {:ok, %Response{status: status, body: body} = response},
         %Request{max_response_bytes: maximum}
       )
       when is_integer(status) and status >= 0 and is_binary(body) do
    cond do
      byte_size(body) > maximum ->
        {:error, {:response_bytes_exceeded, maximum}}

      not valid_response_headers?(
        response.headers,
        @max_response_headers,
        @max_response_header_bytes
      ) ->
        {:error, {:invalid_response, :invalid_headers}}

      true ->
        {:ok, response}
    end
  end

  defp normalize_adapter_result({:error, {:timeout, timeout_ms}} = error, _request)
       when is_integer(timeout_ms) and timeout_ms > 0 and timeout_ms <= @max_timeout_ms,
       do: error

  defp normalize_adapter_result({:error, {:transport_error, reason}} = error, _request)
       when reason in @transport_errors,
       do: error

  defp normalize_adapter_result(
         {:error, {:response_bytes_exceeded, maximum}} = error,
         _request
       )
       when is_integer(maximum) and maximum > 0 and maximum <= @max_response_bytes,
       do: error

  defp normalize_adapter_result(
         {:error, {:invalid_response, reason}} = error,
         _request
       )
       when reason in [:non_identity_content_encoding, :invalid_headers],
       do: error

  defp normalize_adapter_result({:error, {:invalid_request, reason}} = error, _request) do
    if valid_invalid_request_reason?(reason), do: error, else: generic_adapter_error()
  end

  defp normalize_adapter_result(_unknown, _request), do: generic_adapter_error()

  defp valid_invalid_request_reason?(reason) when reason in @invalid_request_atoms, do: true
  defp valid_invalid_request_reason?({:max_response_bytes, :positive_required}), do: true
  defp valid_invalid_request_reason?({:timeout_ms, :positive_required}), do: true

  defp valid_invalid_request_reason?({:max_response_bytes, {:max, @max_response_bytes}}),
    do: true

  defp valid_invalid_request_reason?({:timeout_ms, {:max, @max_timeout_ms}}), do: true
  defp valid_invalid_request_reason?(_reason), do: false

  defp generic_adapter_error, do: {:error, {:transport_error, :other}}

  defp validate(%Request{} = request) do
    cond do
      request.method not in [:get, :post] ->
        {:error, {:invalid_request, :unsupported_method}}

      not (is_binary(request.url) and request.url != "") ->
        {:error, {:invalid_request, :url_required}}

      not (is_integer(request.max_response_bytes) and request.max_response_bytes > 0) ->
        {:error, {:invalid_request, {:max_response_bytes, :positive_required}}}

      not (is_integer(request.timeout_ms) and request.timeout_ms > 0) ->
        {:error, {:invalid_request, {:timeout_ms, :positive_required}}}

      request.max_response_bytes > @max_response_bytes ->
        {:error, {:invalid_request, {:max_response_bytes, {:max, @max_response_bytes}}}}

      request.timeout_ms > @max_timeout_ms ->
        {:error, {:invalid_request, {:timeout_ms, {:max, @max_timeout_ms}}}}

      not is_list(request.headers) ->
        {:error, {:invalid_request, :headers_must_be_list}}

      not valid_headers?(request.headers, @max_request_headers) ->
        {:error, {:invalid_request, :invalid_headers}}

      not (is_nil(request.form) or is_map(request.form)) ->
        {:error, {:invalid_request, :form_must_be_map}}

      true ->
        :ok
    end
  end

  defp valid_headers?([], _remaining), do: true
  defp valid_headers?(_headers, 0), do: false

  defp valid_headers?([{name, value} | rest], remaining)
       when is_binary(name) and is_binary(value) and remaining > 0 do
    cond do
      name == "" ->
        false

      byte_size(name) > @max_request_header_name_bytes ->
        false

      byte_size(value) > @max_request_header_value_bytes ->
        false

      not safe_header_text?(name) ->
        false

      not safe_header_text?(value) ->
        false

      true ->
        valid_headers?(rest, remaining - 1)
    end
  end

  defp valid_headers?(_other, _remaining), do: false

  defp valid_response_headers?([], _remaining_count, _remaining_bytes), do: true
  defp valid_response_headers?(_headers, 0, _remaining_bytes), do: false

  defp valid_response_headers?(
         [{name, value} | rest],
         remaining_count,
         remaining_bytes
       )
       when is_binary(name) and is_binary(value) and remaining_count > 0 do
    encoded_bytes = byte_size(name) + byte_size(value) + 4

    cond do
      name == "" ->
        false

      byte_size(name) > @max_response_header_name_bytes ->
        false

      byte_size(value) > @max_response_header_value_bytes ->
        false

      encoded_bytes > remaining_bytes ->
        false

      not response_header_name?(name) ->
        false

      not response_header_value?(value) ->
        false

      true ->
        valid_response_headers?(
          rest,
          remaining_count - 1,
          remaining_bytes - encoded_bytes
        )
    end
  end

  defp valid_response_headers?(_headers, _remaining_count, _remaining_bytes), do: false

  defp response_header_name?(name) do
    Enum.all?(:binary.bin_to_list(name), fn byte ->
      (byte >= ?a and byte <= ?z) or
        (byte >= ?A and byte <= ?Z) or
        (byte >= ?0 and byte <= ?9) or
        byte in [?!, ?#, ?$, ?%, ?&, ?', ?*, ?+, ?-, ?., ?^, ?_, ?`, ?|, ?~]
    end)
  end

  # RFC field values permit HTAB and obs-text. CR, LF, NUL, and DEL remain
  # forbidden so a custom adapter cannot manufacture a split header.
  defp response_header_value?(value) do
    Enum.all?(:binary.bin_to_list(value), fn byte ->
      byte == ?\t or (byte >= 0x20 and byte != 0x7F)
    end)
  end

  defp safe_header_text?(text) do
    String.valid?(text) and Enum.all?(:binary.bin_to_list(text), &(&1 >= 0x20 and &1 != 0x7F))
  end
end
