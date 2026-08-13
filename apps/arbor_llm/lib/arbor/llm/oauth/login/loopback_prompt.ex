defmodule Arbor.LLM.OAuth.Login.LoopbackPrompt do
  @moduledoc """
  Redacted prompt for an automatic OpenAI localhost callback flow.

  The pending correlation handle is intentionally absent. Callers can only
  deliberately retrieve the authorization URL.
  """

  @enforce_keys [:authorize_url]
  defstruct [:authorize_url]

  @type t :: %__MODULE__{authorize_url: String.t()}

  @doc "The authorization URL to open in a browser."
  @spec authorize_url(t()) :: String.t()
  def authorize_url(%__MODULE__{authorize_url: url}), do: url

  defimpl Inspect do
    def inspect(_prompt, _opts),
      do: "#Arbor.LLM.OAuth.Login.LoopbackPrompt<redacted>"
  end
end
