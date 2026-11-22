defmodule Arbor.LLM.OAuth.Login.LoopbackPrompt do
  @moduledoc """
  Redacted prompt for an automatic OpenAI localhost callback flow.

  The pending correlation handle is intentionally absent. Callers can only
  deliberately retrieve the authorization URL and the non-secret flow handle
  used to await this flow's own terminal result.
  """

  alias Arbor.LLM.OAuth.Login.LoopbackFlow

  @enforce_keys [:authorize_url, :flow]
  defstruct [:authorize_url, :flow]

  @type t :: %__MODULE__{authorize_url: String.t(), flow: LoopbackFlow.t()}

  @doc "The authorization URL to open in a browser."
  @spec authorize_url(t()) :: String.t()
  def authorize_url(%__MODULE__{authorize_url: url}), do: url

  @doc "Opaque, non-secret handle that correlates an await to this flow."
  @spec flow(t()) :: LoopbackFlow.t()
  def flow(%__MODULE__{flow: flow}), do: flow

  defimpl Inspect do
    def inspect(_prompt, _opts),
      do: "#Arbor.LLM.OAuth.Login.LoopbackPrompt<redacted>"
  end
end
