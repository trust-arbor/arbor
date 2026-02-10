defmodule Arbor.Orchestrator.UnifiedLLM.ProviderError do
  @moduledoc false

  defexception [:message, :provider, :status, :retryable, :retry_after_ms, :code, :details]

  @type t :: %__MODULE__{
          message: String.t(),
          provider: String.t() | nil,
          status: integer() | nil,
          retryable: boolean(),
          retry_after_ms: integer() | nil,
          code: String.t() | nil,
          details: map() | nil
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
      details: Keyword.get(opts, :details)
    }
  end
end
