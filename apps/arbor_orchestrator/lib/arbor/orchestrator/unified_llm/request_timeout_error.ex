defmodule Arbor.Orchestrator.UnifiedLLM.RequestTimeoutError do
  @moduledoc false

  defexception [:message, :timeout_ms]

  @type t :: %__MODULE__{
          message: String.t(),
          timeout_ms: integer() | nil
        }

  @spec exception(keyword()) :: t()
  def exception(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms)

    message =
      Keyword.get(opts, :message, "Request timed out")
      |> maybe_append_timeout(timeout_ms)

    %__MODULE__{message: message, timeout_ms: timeout_ms}
  end

  defp maybe_append_timeout(message, timeout_ms) when is_integer(timeout_ms),
    do: "#{message} (timeout_ms=#{timeout_ms})"

  defp maybe_append_timeout(message, _), do: message
end
