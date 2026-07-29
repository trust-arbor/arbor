defmodule Arbor.LLM.OAuth.ResponsesFailure do
  @moduledoc """
  The one typed failure returned by the subscription Responses transport
  (`Arbor.LLM.OAuth.Responses`).

  Boundedness is enforced by **construction, not by declaration**. Elixir struct
  fields are untyped at runtime, so `exception/1` — the only way production code
  builds this struct, including via `from_status/4`, `transport/3`, and
  `protocol/3` — normalizes every field into a closed domain: `route` and
  `backend` must form a valid pair, and `class` and `code` must be members of
  their literal tables, or they collapse to a safe default; `status` must be
  `100..599`; `retry_after_ms` must be a
  bounded non-negative millisecond count; `retryable` is derived from the closed class/code table.
  A value outside its
  domain (a raw body, a bearer token, a path) is therefore dropped rather than
  carried, so `Exception.message/1` and `inspect/1` stay bounded and
  secret-free. The normalization is asserted directly against these production
  constructors in `oauth_responses_test.exs`.

  `route` is the exact Arbor OAuth route ID the caller used and is `nil` only
  for the low-level `Responses.request_sse/4` arity, which has no route
  identity to report. It is never inferred and never defaulted.
  """

  defexception [:route, :backend, :class, :code, :status, :retryable, :retry_after_ms]

  @backends [:openai, :xai]
  @classes [:auth, :forbidden, :tier_denied, :quota, :provider_outage, :transport, :protocol]

  # Closed code set. Each entry maps to its class and default retryability;
  # every member has a producer in Arbor.LLM.OAuth.Responses.
  @code_table %{
    unauthorized: {:auth, false},
    forbidden: {:forbidden, false},
    xai_oauth_tier_denied: {:tier_denied, false},
    rate_limited: {:quota, true},
    server_error: {:provider_outage, true},
    unexpected_status: {:protocol, false},
    request_timeout: {:transport, true},
    deadline_exceeded: {:transport, true},
    connection_failed: {:transport, true},
    response_bytes_exceeded: {:protocol, false},
    invalid_response_headers: {:protocol, false},
    invalid_stream: {:protocol, false}
  }

  @max_retry_after_ms 86_400_000

  @type route :: :openai_oauth | :xai_oauth | nil
  @type backend :: :openai | :xai | nil
  @type class ::
          :auth | :forbidden | :tier_denied | :quota | :provider_outage | :transport | :protocol

  @type t :: %__MODULE__{
          route: route(),
          backend: backend(),
          class: class(),
          code: atom(),
          status: 100..599 | nil,
          retryable: boolean(),
          retry_after_ms: non_neg_integer() | nil
        }

  @spec codes() :: [atom()]
  def codes, do: Map.keys(@code_table)

  @spec classes() :: [class()]
  def classes, do: @classes

  @doc """
  Returns true when the `class` and `code` combination is valid in the closed
  failure table.
  """
  @spec valid_class_code?(class() | nil, atom() | nil) :: boolean()
  def valid_class_code?(class, code) do
    case Map.fetch(@code_table, code) do
      {:ok, {table_class, _retryable}} -> table_class == class
      :error -> false
    end
  end

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
      retryable: retryable,
      retry_after_ms: retry_after_ms(Keyword.get(opts, :retry_after_ms))
    }
  end

  @impl true
  def message(%__MODULE__{} = failure) do
    "oauth responses failure: #{failure.route || "unrouted"}/#{failure.backend || "unknown"} " <>
      "#{failure.class} (status=#{failure.status || "none"}, code=#{failure.code}, " <>
      "retryable=#{failure.retryable}, retry_after_ms=#{failure.retry_after_ms || "none"})"
  end

  @doc """
  Classify a non-200 HTTP status. `tier_denied?` must come from an explicitly
  parsed, allow-listed structured provider error code — never from a substring
  scan and never from a generic 403.
  """
  @spec from_status(route(), backend(), integer(), keyword()) :: t()
  def from_status(route, backend, status, opts \\ []) when is_integer(status) do
    tier_denied? = Keyword.get(opts, :tier_denied?, false) == true

    code =
      cond do
        status == 401 -> :unauthorized
        status == 403 and tier_denied? and backend == :xai -> :xai_oauth_tier_denied
        status == 403 -> :forbidden
        status == 408 -> :request_timeout
        status == 429 -> :rate_limited
        status >= 500 and status <= 599 -> :server_error
        true -> :unexpected_status
      end

    exception(
      route: route,
      backend: backend,
      status: status,
      code: code,
      retry_after_ms: Keyword.get(opts, :retry_after_ms)
    )
  end

  @doc "Transport-class failure. An out-of-domain `code` normalizes rather than raising."
  @spec transport(route(), backend(), atom()) :: t()
  def transport(route, backend, code) do
    exception(route: route, backend: backend, code: transport_code(code))
  end

  @doc "Protocol-class failure. An out-of-domain `code` normalizes rather than raising."
  @spec protocol(route(), backend(), atom()) :: t()
  def protocol(route, backend, code) do
    exception(route: route, backend: backend, code: protocol_code(code))
  end

  defp transport_code(code)
       when code in [:request_timeout, :deadline_exceeded, :connection_failed],
       do: code

  defp transport_code(_code), do: :connection_failed

  defp protocol_code(code)
       when code in [:response_bytes_exceeded, :invalid_response_headers, :invalid_stream],
       do: code

  defp protocol_code(_code), do: :invalid_stream

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

  defp retry_after_ms(ms) when is_integer(ms) and ms >= 0 and ms <= @max_retry_after_ms, do: ms
  defp retry_after_ms(_ms), do: nil
end
