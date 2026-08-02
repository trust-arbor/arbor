defmodule Arbor.Voice.Redacted do
  @moduledoc """
  Opaque wrapper for values that must never appear in `Inspect`, `format_status/1`,
  logs, or returned errors. Used for backend opts, opaque backend handles, and
  cleanup closures inside `Arbor.Voice.ResourceOwner`.
  """

  defstruct [:value]

  @type t :: %__MODULE__{value: term()}

  def new(value), do: %__MODULE__{value: value}

  def value(%__MODULE__{value: value}), do: value

  defimpl Inspect do
    def inspect(_redacted, _opts), do: "#Redacted<>"
  end
end
