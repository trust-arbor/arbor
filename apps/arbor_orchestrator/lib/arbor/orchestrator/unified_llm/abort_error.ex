defmodule Arbor.Orchestrator.UnifiedLLM.AbortError do
  @moduledoc false

  defexception [:message, :reason]

  @type t :: %__MODULE__{
          message: String.t(),
          reason: term()
        }

  @spec exception(keyword()) :: t()
  def exception(opts) do
    reason = Keyword.get(opts, :reason, :aborted)
    message = Keyword.get(opts, :message, "Request aborted")
    %__MODULE__{message: message, reason: reason}
  end
end
