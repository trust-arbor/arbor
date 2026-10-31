defmodule Arbor.LLM.ProviderError do
  @moduledoc """
  The one typed failure of a provider request.

  Every failure `Arbor.LLM.Plugs.Dispatch` produces is a `%ProviderError{}`
  (a deadline expiry stays `%Arbor.LLM.RequestTimeoutError{}`, the umbrella's
  single timeout type). Consumers — `Plugs.RateLimitBackoff`,
  `Arbor.LLM.Retry`, provider fallback, `Arbor.AI.LLMError`, agent loops —
  decide on the typed fields, never on `message` text:

    * `status` — the provider's HTTP status, or `nil` when no status arrived
    * `retryable` — a transient failure worth same-path retry or fallback
    * `retry_after_ms` — the delay the provider asked for, when it sent one
    * `context_window_exceeded` — the request did not fit the model's context
      window; never retryable as-is (compact or switch models instead)
    * `original` — the untranslated failure (the `%Req.Response{}`, exception,
      or reason term) kept as data, never reduced to text. `Arbor.LLM.Boundary`
      bounds it with `Arbor.LLM.ExternalTerm.sanitize/1` if it exceeds the
      adapter-error budget; the other fields always survive.

  `message` is human-readable text for logs. Classification lives in
  `Arbor.LLM.ProviderErrorCore`.
  """

  defexception [
    :message,
    :provider,
    :status,
    :retryable,
    :retry_after_ms,
    :code,
    :details,
    :original,
    context_window_exceeded: false
  ]

  @type t :: %__MODULE__{
          message: String.t(),
          provider: String.t() | nil,
          status: integer() | nil,
          retryable: boolean(),
          retry_after_ms: integer() | nil,
          code: String.t() | nil,
          details: map() | nil,
          original: term(),
          context_window_exceeded: boolean()
        }

  @impl true
  def exception(opts) do
    %__MODULE__{
      message: Keyword.get(opts, :message, "provider error"),
      provider: Keyword.get(opts, :provider),
      status: Keyword.get(opts, :status),
      retryable: Keyword.get(opts, :retryable, true),
      retry_after_ms: Keyword.get(opts, :retry_after_ms),
      code: Keyword.get(opts, :code),
      details: Keyword.get(opts, :details),
      original: Keyword.get(opts, :original),
      context_window_exceeded: Keyword.get(opts, :context_window_exceeded, false)
    }
  end
end
