defmodule Arbor.LLM.OAuth.Login.LoopbackFlow do
  @moduledoc """
  Opaque, non-secret correlation handle for one OpenAI loopback login.

  Carries no token, authorization-code, PKCE, or pending-handle material.
  Equality is the only supported inspection: two values refer to the same
  flow when they match.
  """

  @enforce_keys [:id]
  defstruct [:id]

  @type t :: %__MODULE__{id: reference()}

  @doc false
  @spec new(reference()) :: t()
  def new(id) when is_reference(id), do: %__MODULE__{id: id}

  @doc false
  @spec id(t()) :: reference()
  def id(%__MODULE__{id: id}), do: id

  defimpl Inspect do
    def inspect(_flow, _opts),
      do: "#Arbor.LLM.OAuth.Login.LoopbackFlow<redacted>"
  end
end
