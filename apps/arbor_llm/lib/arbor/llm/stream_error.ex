defmodule Arbor.LLM.StreamError do
  @moduledoc false
  defexception [:reason]

  @impl true
  def message(%__MODULE__{reason: reason}),
    do: "owned stream failed: #{Arbor.LLM.ExternalTerm.inspect(reason)}"
end
