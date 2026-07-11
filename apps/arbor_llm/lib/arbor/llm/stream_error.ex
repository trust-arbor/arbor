defmodule Arbor.LLM.StreamError do
  @moduledoc false
  defexception [:reason]

  @impl true
  def message(%__MODULE__{reason: reason}),
    do: "owned stream failed: #{inspect(reason, limit: 20, printable_limit: 512)}"
end
