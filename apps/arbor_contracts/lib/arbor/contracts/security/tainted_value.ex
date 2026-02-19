defmodule Arbor.Contracts.Security.TaintedValue do
  @moduledoc """
  A value wrapped with its taint metadata.

  Provides explicit taint tracking at the type level. Any code that receives a
  TaintedValue must either:
  - Propagate the taint through transformation
  - Deliberately discard it via `unwrap!/1` (the `!` signals conscious choice)

  Council decision #9: struct (11/13 votes), not tuple.
  """

  use TypedStruct

  alias Arbor.Contracts.Security.Taint

  @derive Jason.Encoder
  typedstruct enforce: true do
    field :value, term()
    field :taint, Taint.t()
  end

  @doc "Wrap a value with explicit taint metadata."
  @spec wrap(term(), Taint.t()) :: t()
  def wrap(value, %Taint{} = taint) do
    %__MODULE__{value: value, taint: taint}
  end

  @doc """
  Deliberately discard taint and extract the raw value.

  The `!` suffix signals this is a conscious decision to ignore taint.
  """
  @spec unwrap!(t()) :: term()
  def unwrap!(%__MODULE__{value: value}), do: value

  @doc "Wrap a value as fully trusted public data."
  @spec trusted(term()) :: t()
  def trusted(value) do
    wrap(value, %Taint{level: :trusted, sensitivity: :public, confidence: :verified})
  end

  @doc "Wrap a value with default (conservative) taint."
  @spec unknown(term()) :: t()
  def unknown(value) do
    wrap(value, %Taint{})
  end

  @doc "Check if the wrapped value has a specific taint level."
  @spec level?(t(), Taint.level()) :: boolean()
  def level?(%__MODULE__{taint: %Taint{level: level}}, expected), do: level == expected

  @doc "Check if the wrapped value has at most the given sensitivity."
  @spec sensitivity_at_most?(t(), Taint.sensitivity()) :: boolean()
  def sensitivity_at_most?(%__MODULE__{taint: %Taint{sensitivity: actual}}, max_sensitivity) do
    sensitivity_rank(actual) <= sensitivity_rank(max_sensitivity)
  end

  defp sensitivity_rank(:public), do: 0
  defp sensitivity_rank(:internal), do: 1
  defp sensitivity_rank(:confidential), do: 2
  defp sensitivity_rank(:restricted), do: 3
end
