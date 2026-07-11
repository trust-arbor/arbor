defmodule Arbor.LLM.OwnedStream do
  @moduledoc false

  @enforce_keys [:stream, :cancel, :producer]
  defstruct [:stream, :cancel, :producer]
end

defimpl Enumerable, for: Arbor.LLM.OwnedStream do
  def reduce(%{stream: stream}, acc, fun), do: Enumerable.reduce(stream, acc, fun)
  def count(_stream), do: {:error, __MODULE__}
  def member?(_stream, _value), do: {:error, __MODULE__}
  def slice(_stream), do: {:error, __MODULE__}
end
