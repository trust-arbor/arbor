defmodule Arbor.Orchestrator.Engine.Context do
  @moduledoc false

  @type t :: %__MODULE__{values: map(), logs: [String.t()], lineage: map()}
  defstruct values: %{}, logs: [], lineage: %{}

  @spec new(map()) :: t()
  def new(values \\ %{}), do: %__MODULE__{values: values}

  @spec get(t(), String.t(), term()) :: term()
  def get(%__MODULE__{values: values}, key, default \\ nil), do: Map.get(values, key, default)

  @doc "Set a context value without tracking lineage."
  @spec set(t(), String.t(), term()) :: t()
  def set(%__MODULE__{values: values} = ctx, key, value),
    do: %{ctx | values: Map.put(values, key, value)}

  @doc "Set a context value and record which node set it."
  @spec set(t(), String.t(), term(), String.t()) :: t()
  def set(%__MODULE__{values: values, lineage: lineage} = ctx, key, value, node_id)
      when is_binary(node_id) do
    %{ctx | values: Map.put(values, key, value), lineage: Map.put(lineage, key, node_id)}
  end

  @doc "Merge updates into context without tracking lineage."
  @spec apply_updates(t(), map()) :: t()
  def apply_updates(%__MODULE__{} = ctx, updates) when is_map(updates) do
    %{ctx | values: Map.merge(ctx.values, updates)}
  end

  @doc "Merge updates into context and record which node set each key."
  @spec apply_updates(t(), map(), String.t()) :: t()
  def apply_updates(%__MODULE__{values: values, lineage: lineage} = ctx, updates, node_id)
      when is_map(updates) and is_binary(node_id) do
    new_lineage =
      updates
      |> Map.keys()
      |> Enum.reduce(lineage, fn key, acc -> Map.put(acc, key, node_id) end)

    %{ctx | values: Map.merge(values, updates), lineage: new_lineage}
  end

  @doc "Returns the node_id that last set the given context key, or nil."
  @spec origin(t(), String.t()) :: String.t() | nil
  def origin(%__MODULE__{lineage: lineage}, key), do: Map.get(lineage, key)

  @doc "Returns the full lineage map."
  @spec lineage(t()) :: map()
  def lineage(%__MODULE__{lineage: lineage}), do: lineage

  @spec snapshot(t()) :: map()
  def snapshot(%__MODULE__{values: values}), do: values
end
