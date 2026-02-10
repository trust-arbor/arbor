defmodule Arbor.Orchestrator.UnifiedLLM.NoObjectGeneratedError do
  @moduledoc false

  defexception [:message, :reason]

  @type t :: %__MODULE__{
          message: String.t(),
          reason: term()
        }

  @spec exception(keyword()) :: t()
  def exception(opts) do
    reason = Keyword.get(opts, :reason, :no_object_generated)
    message = Keyword.get(opts, :message, "No valid object could be generated")
    %__MODULE__{message: message, reason: reason}
  end
end
