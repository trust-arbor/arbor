defmodule Arbor.Orchestrator.Graph.Edge do
  @moduledoc false

  @type t :: %__MODULE__{from: String.t(), to: String.t(), attrs: map()}
  defstruct from: "", to: "", attrs: %{}

  @spec attr(t(), String.t() | atom(), term()) :: term()
  def attr(edge, key, default \\ nil)

  def attr(%__MODULE__{attrs: attrs}, key, default) when is_atom(key) do
    attr(%__MODULE__{attrs: attrs}, Atom.to_string(key), default)
  end

  def attr(%__MODULE__{attrs: attrs}, key, default) when is_binary(key) do
    Map.get(attrs, key, default)
  end
end
