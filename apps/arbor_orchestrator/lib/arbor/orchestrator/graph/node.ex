defmodule Arbor.Orchestrator.Graph.Node do
  @moduledoc false

  @type t :: %__MODULE__{id: String.t(), attrs: map()}
  defstruct id: "", attrs: %{}

  @spec attr(t(), String.t() | atom(), term()) :: term()
  def attr(node, key, default \\ nil)

  def attr(%__MODULE__{attrs: attrs}, key, default) when is_atom(key) do
    attr(%__MODULE__{attrs: attrs}, Atom.to_string(key), default)
  end

  def attr(%__MODULE__{attrs: attrs}, key, default) when is_binary(key) do
    Map.get(attrs, key, default)
  end
end
