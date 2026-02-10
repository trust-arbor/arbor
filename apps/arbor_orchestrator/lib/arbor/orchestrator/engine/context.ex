defmodule Arbor.Orchestrator.Engine.Context do
  @moduledoc false

  @type t :: %__MODULE__{values: map(), logs: [String.t()]}
  defstruct values: %{}, logs: []

  @spec new(map()) :: t()
  def new(values \\ %{}), do: %__MODULE__{values: values}

  @spec get(t(), String.t(), term()) :: term()
  def get(%__MODULE__{values: values}, key, default \\ nil), do: Map.get(values, key, default)

  @spec set(t(), String.t(), term()) :: t()
  def set(%__MODULE__{values: values} = ctx, key, value),
    do: %{ctx | values: Map.put(values, key, value)}

  @spec apply_updates(t(), map()) :: t()
  def apply_updates(%__MODULE__{} = ctx, updates) when is_map(updates) do
    %{ctx | values: Map.merge(ctx.values, updates)}
  end

  @spec snapshot(t()) :: map()
  def snapshot(%__MODULE__{values: values}), do: values
end
