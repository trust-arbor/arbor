defmodule Arbor.Orchestrator.Handlers.InvalidReturnError do
  defexception [:message]

  @impl true
  def exception(msg) when is_binary(msg) do
    %__MODULE__{message: msg}
  end
end