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

  @provider_error_mod Arbor.Orchestrator.UnifiedLLM.ProviderError
  @timeout_error_mod Arbor.Orchestrator.UnifiedLLM.RequestTimeoutError

  @doc """
  Classify an error reason into a structured, signal-safe map.

  Handles known error structs (`ProviderError`, `RequestTimeoutError`),
  tagged tuples (`:bridge_exception`, `:bridge_exit`, `:oauth_failed`,
  `:sensitivity_blocked`), atoms, strings, and falls back to `:unknown`.
  """
  @spec classify(term()) :: error_info()
  def classify(reason) do
    do_classify(reason)
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

  defp safe_message(nil), do: "unknown error"
  defp safe_message(msg) when is_binary(msg), do: truncate(msg, 200)
  defp safe_message(msg), do: truncate(inspect(msg), 200)

  defp safe_provider(nil), do: nil
  defp safe_provider(p) when is_atom(p), do: p

  defp safe_provider(p) when is_binary(p) do
    String.to_existing_atom(p)
  rescue
    ArgumentError -> nil
  end

  defp safe_inspect(term) do
    inspect(term, limit: 5, printable_limit: 200)
  end

  defp truncate(str, max) when is_binary(str) do
    if String.length(str) > max do
      String.slice(str, 0, max) <> "..."
    else
      str
    end
  end
end
