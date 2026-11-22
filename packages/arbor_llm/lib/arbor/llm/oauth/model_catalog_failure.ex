defmodule Arbor.LLM.OAuth.ModelCatalogFailure do
  @moduledoc """
  Closed, redacted failure for the subscription model-catalog transport.

  Boundedness is enforced by construction: only closed route/backend pairs,
  classes, codes, and optional HTTP status integers are retained. Response
  bodies, tokens, account IDs, paths, and arbitrary upstream text are dropped.
  """

  defexception [:route, :backend, :class, :code, :status, :retryable]

  @backends [:openai, :xai]

  @code_table %{
    unauthorized: {:auth, false},
    forbidden: {:forbidden, false},
    rate_limited: {:quota, true},
    server_error: {:provider_outage, true},
    unexpected_status: {:protocol, false},
    request_timeout: {:transport, true},
    deadline_exceeded: {:transport, true},
    connection_failed: {:transport, true},
    response_bytes_exceeded: {:protocol, false},
    invalid_response_headers: {:protocol, false},
    malformed_catalog: {:protocol, false},
    empty_catalog: {:protocol, false},
    empty_raw_body: {:protocol, false},
    duplicate_model_id: {:protocol, false},
    catalog_too_large: {:protocol, false},
    forbidden_option: {:options, false},
    keyword_options_required: {:options, false},
    invalid_options: {:options, false},
    invalid_credential_receipt: {:options, false}
  }

  @type route :: :openai_oauth | :xai_oauth | nil
  @type backend :: :openai | :xai | nil
  @type class ::
          :auth
          | :forbidden
          | :quota
          | :provider_outage
          | :transport
          | :protocol
          | :options

  @type t :: %__MODULE__{
          route: route(),
          backend: backend(),
          class: class(),
          code: atom(),
          status: 100..599 | nil,
          retryable: boolean()
        }

  @spec codes() :: [atom()]
  def codes, do: Map.keys(@code_table)

  @impl true
  def exception(opts) when is_list(opts) do
    code = code(Keyword.get(opts, :code))
    {class, retryable} = Map.fetch!(@code_table, code)
    {route, backend} = identity(Keyword.get(opts, :route), Keyword.get(opts, :backend))

    %__MODULE__{
      route: route,
      backend: backend,
      class: class,
      code: code,
      status: status(Keyword.get(opts, :status)),
      retryable: retryable
    }
  end

  @impl true
  def message(%__MODULE__{} = failure) do
    "oauth model catalog failure: #{failure.route || "unrouted"}/#{failure.backend || "unknown"} " <>
      "#{failure.class} (status=#{failure.status || "none"}, code=#{failure.code}, " <>
      "retryable=#{failure.retryable})"
  end

  @spec from_status(route(), backend(), integer()) :: t()
  def from_status(route, backend, status) when is_integer(status) do
    code =
      cond do
        status == 401 -> :unauthorized
        status == 403 -> :forbidden
        status == 408 -> :request_timeout
        status == 429 -> :rate_limited
        status >= 500 and status <= 599 -> :server_error
        true -> :unexpected_status
      end

    exception(route: route, backend: backend, status: status, code: code)
  end

  @spec transport(route(), backend(), atom()) :: t()
  def transport(route, backend, code),
    do: exception(route: route, backend: backend, code: transport_code(code))

  @spec protocol(route(), backend(), atom()) :: t()
  def protocol(route, backend, code),
    do: exception(route: route, backend: backend, code: protocol_code(code))

  @spec options(atom()) :: t()
  def options(code), do: exception(route: nil, backend: nil, code: options_code(code))

  defp transport_code(code)
       when code in [:request_timeout, :deadline_exceeded, :connection_failed],
       do: code

  defp transport_code(_code), do: :connection_failed

  defp protocol_code(code)
       when code in [
              :response_bytes_exceeded,
              :invalid_response_headers,
              :malformed_catalog,
              :empty_catalog,
              :empty_raw_body,
              :duplicate_model_id,
              :catalog_too_large
            ],
       do: code

  defp protocol_code(_code), do: :malformed_catalog

  defp options_code(code)
       when code in [
              :forbidden_option,
              :keyword_options_required,
              :invalid_options,
              :invalid_credential_receipt
            ],
       do: code

  defp options_code(_code), do: :invalid_options

  defp code(code) when is_atom(code) and not is_nil(code) do
    if Map.has_key?(@code_table, code), do: code, else: :unexpected_status
  end

  defp code(_code), do: :unexpected_status

  defp identity(:openai_oauth, :openai), do: {:openai_oauth, :openai}
  defp identity(:xai_oauth, :xai), do: {:xai_oauth, :xai}
  defp identity(nil, backend) when backend in @backends, do: {nil, backend}
  defp identity(nil, nil), do: {nil, nil}
  defp identity(_route, _backend), do: {nil, nil}

  defp status(status) when is_integer(status) and status >= 100 and status <= 599, do: status
  defp status(_status), do: nil
end
