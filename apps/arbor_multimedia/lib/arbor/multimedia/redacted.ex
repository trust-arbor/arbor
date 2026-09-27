defmodule Arbor.Multimedia.Redacted do
  @moduledoc false
  defstruct [:value]
  def new(value), do: %__MODULE__{value: value}

  defimpl Inspect do
    def inspect(_, _), do: "#Arbor.Multimedia.Redacted<>"
  end
end
