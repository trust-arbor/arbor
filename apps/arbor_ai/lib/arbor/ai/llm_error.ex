defmodule Arbor.AI.LLMError do
  @moduledoc """
  Classifies LLM errors into structured, signal-safe data.

  Converts raw error reasons into a consistent map format suitable for
  signal emission and observability, without leaking sensitive data
  (API keys, full prompts, full responses, file contents).
  """

  @type error_info :: %{
          type: atom(),
          message: String.t(),
          status: integer() | nil,
          code: String.t() | nil,
          retryable: boolean(),
          retry_after_ms: integer() | nil,
          provider: atom() | nil
        }

  @provider_error_mod Arbor.LLM.ProviderError
  @timeout_error_mod Arbor.LLM.RequestTimeoutError
  @responses_failure_mod Arbor.LLM.OAuth.ResponsesFailure
  @oauth_routes MapSet.new([:openai_oauth, :xai_oauth])

  @doc """
  Classify an error reason into a structured, signal-safe map.

  Handles known error structs (`ProviderError`, `RequestTimeoutError`,
  `ResponsesFailure`), tagged tuples (`:bridge_exception`, `:bridge_exit`,
  `:oauth_failed`, `:sensitivity_blocked`), atoms, strings, and falls back
  to `:unknown`. Pure — never writes control-plane state.
  """
  @spec classify(term()) :: error_info()
  def classify(reason) do
    do_classify(reason)
  end

  # Exact closed {type, code} → control-plane effect. Type-only maps are no-ops.
  @effect_table %{
    {:rate_limited, "rate_limited"} => {:quota, :rate_limited},
    {:auth_failure, "unauthorized"} => {:route_failure, :auth},
    {:auth_failure, "forbidden"} => {:route_failure, :auth},
    {:auth_failure, "xai_oauth_tier_denied"} => {:route_failure, :tier_denied},
    {:provider_error, "server_error"} => {:route_failure, :outage},
    {:timeout, "request_timeout"} => {:route_failure, :transport},
    {:timeout, "deadline_exceeded"} => {:route_failure, :transport},
    {:network, "connection_failed"} => {:route_failure, :transport},
    {:provider_error, "unexpected_status"} => {:route_failure, :protocol},
    {:provider_error, "response_bytes_exceeded"} => {:route_failure, :protocol},
    {:provider_error, "invalid_response_headers"} => {:route_failure, :protocol},
    {:provider_error, "invalid_stream"} => {:route_failure, :protocol}
  }

  @doc """
  Pure control-plane effect for a classified error_info map.

  Returns `{:quota, :rate_limited}`, `{:route_failure, class}`, or `:none`.
  Only exact closed `{type, code}` pairs admit effects — type-only maps are
  no-ops. Does not inspect free-text messages.
  """
  @spec control_plane_effect(map()) ::
          {:quota, :rate_limited} | {:route_failure, atom()} | :none
  def control_plane_effect(%{type: type, code: code})
      when is_atom(type) and is_binary(code) do
    Map.get(@effect_table, {type, code}, :none)
  end

  def control_plane_effect(_), do: :none

  # ── ResponsesFailure ───────────────────────────────────────────────

  defp do_classify(%{__struct__: mod} = err) when mod == @responses_failure_mod do
    type = responses_type(err.class, err.code)

    %{
      type: type,
      message: truncate(Exception.message(err), 200),
      status: err.status,
      code: responses_code(err.code),
      retryable: err.retryable == true,
      retry_after_ms: bounded_retry_after(err.retry_after_ms),
      provider: exact_oauth_route(err.route)
    }
  end

  # ── ProviderError ──────────────────────────────────────────────────

  defp do_classify(%{__struct__: mod} = err) when mod == @provider_error_mod do
    type =
      cond do
        err.status == 429 -> :rate_limited
        err.status == 401 or err.status == 403 -> :auth_failure
        err.status != nil and err.status >= 500 -> :provider_error
        true -> :provider_error
      end

    %{
      type: type,
      message: safe_message(err.message),
      status: err.status,
      code: err.code,
      retryable: err.retryable || false,
      retry_after_ms: err.retry_after_ms,
      provider: safe_provider(err.provider)
    }
  end

  # ── RequestTimeoutError ────────────────────────────────────────────

  defp do_classify(%{__struct__: mod} = err) when mod == @timeout_error_mod do
    %{
      type: :timeout,
      message: safe_message(err.message),
      status: nil,
      code: nil,
      retryable: true,
      retry_after_ms: nil,
      provider: nil
    }
  end

  # ── Tagged tuples ──────────────────────────────────────────────────

  defp do_classify({:bridge_exception, msg}) when is_binary(msg) do
    %{
      type: :bridge_error,
      message: truncate("Bridge exception: #{msg}", 200),
      status: nil,
      code: nil,
      retryable: false,
      retry_after_ms: nil,
      provider: nil
    }
  end

  defp do_classify({:bridge_exit, reason}) do
    %{
      type: :bridge_error,
      message: truncate("Bridge exit: #{safe_inspect(reason)}", 200),
      status: nil,
      code: nil,
      retryable: true,
      retry_after_ms: nil,
      provider: nil
    }
  end

  defp do_classify({:oauth_failed, reason}) do
    %{
      type: :auth_failure,
      message: truncate("OAuth failed: #{safe_inspect(reason)}", 200),
      status: nil,
      code: nil,
      retryable: false,
      retry_after_ms: nil,
      provider: nil
    }
  end

  defp do_classify({:sensitivity_blocked, reason}) do
    %{
      type: :sensitivity_blocked,
      message: truncate("Blocked by sensitivity: #{safe_inspect(reason)}", 200),
      status: nil,
      code: nil,
      retryable: false,
      retry_after_ms: nil,
      provider: nil
    }
  end

  defp do_classify({:http_status, status}) when is_integer(status) do
    type =
      cond do
        status == 429 -> :rate_limited
        status in [401, 403] -> :auth_failure
        status >= 500 -> :provider_error
        true -> :provider_error
      end

    %{
      type: type,
      message: "HTTP #{status}",
      status: status,
      code: nil,
      retryable: status == 429 or status >= 500,
      retry_after_ms: nil,
      provider: nil
    }
  end

  # ── Atoms ──────────────────────────────────────────────────────────

  defp do_classify(:timeout) do
    %{
      type: :timeout,
      message: "Request timed out",
      status: nil,
      code: nil,
      retryable: true,
      retry_after_ms: nil,
      provider: nil
    }
  end

  defp do_classify(:rate_limited) do
    %{
      type: :rate_limited,
      message: "Rate limited",
      status: 429,
      code: nil,
      retryable: true,
      retry_after_ms: nil,
      provider: nil
    }
  end

  defp do_classify(:network_error) do
    %{
      type: :network,
      message: "Network error",
      status: nil,
      code: nil,
      retryable: true,
      retry_after_ms: nil,
      provider: nil
    }
  end

  # ── Strings ────────────────────────────────────────────────────────

  defp do_classify(reason) when is_binary(reason) do
    %{
      type: :unknown,
      message: truncate(reason, 200),
      status: nil,
      code: nil,
      retryable: false,
      retry_after_ms: nil,
      provider: nil
    }
  end

  # ── Fallback ───────────────────────────────────────────────────────

  defp do_classify(reason) do
    %{
      type: :unknown,
      message: truncate(safe_inspect(reason), 200),
      status: nil,
      code: nil,
      retryable: false,
      retry_after_ms: nil,
      provider: nil
    }
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp responses_type(:auth, _code), do: :auth_failure
  defp responses_type(:forbidden, _code), do: :auth_failure
  defp responses_type(:tier_denied, _code), do: :auth_failure
  defp responses_type(:quota, _code), do: :rate_limited
  defp responses_type(:provider_outage, _code), do: :provider_error
  defp responses_type(:transport, :connection_failed), do: :network
  defp responses_type(:transport, _code), do: :timeout
  defp responses_type(:protocol, _code), do: :provider_error
  defp responses_type(_class, _code), do: :unknown

  defp responses_code(code) when is_atom(code) and not is_nil(code), do: Atom.to_string(code)
  defp responses_code(_), do: nil

  defp exact_oauth_route(route) when is_atom(route) do
    if MapSet.member?(@oauth_routes, route), do: route, else: nil
  end

  defp exact_oauth_route(_), do: nil

  defp bounded_retry_after(ms) when is_integer(ms) and ms >= 0 and ms <= 86_400_000, do: ms
  defp bounded_retry_after(_), do: nil

  defp safe_message(nil), do: "unknown error"
  defp safe_message(msg) when is_binary(msg), do: truncate(msg, 200)
  defp safe_message(msg), do: truncate(Arbor.LLM.inspect_external_reason(msg), 200)

  defp safe_provider(nil), do: nil
  defp safe_provider(p) when is_atom(p), do: p

  defp safe_provider(p) when is_binary(p) do
    String.to_existing_atom(p)
  rescue
    ArgumentError -> nil
  end

  defp safe_inspect(term), do: Arbor.LLM.inspect_external_reason(term)

  defp truncate(str, max) when is_binary(str) do
    if String.length(str) > max do
      String.slice(str, 0, max) <> "..."
    else
      str
    end
  end
end
