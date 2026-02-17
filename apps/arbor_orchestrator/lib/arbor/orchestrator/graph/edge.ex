defmodule Arbor.Orchestrator.Graph.Edge do
  @moduledoc false

  @type t :: %__MODULE__{
          from: String.t(),
          to: String.t(),
          attrs: map(),
          # Typed fields populated from attrs via from_attrs/3
          condition: String.t() | nil,
          label: String.t() | nil,
          weight: non_neg_integer() | nil,
          fidelity: String.t() | nil,
          thread_id: String.t() | nil,
          loop_restart: boolean()
        }

  defstruct from: "",
            to: "",
            attrs: %{},
            condition: nil,
            label: nil,
            weight: nil,
            fidelity: nil,
            thread_id: nil,
            loop_restart: false

  @known_attrs ~w(condition label weight fidelity thread_id loop_restart)

  @doc "List of attribute keys that have typed struct fields."
  @spec known_attrs() :: [String.t()]
  def known_attrs, do: @known_attrs

  @doc "Populate typed fields from the attrs map."
  @spec from_attrs(String.t(), String.t(), map()) :: t()
  def from_attrs(from, to, attrs) when is_map(attrs) do
    %__MODULE__{
      from: from,
      to: to,
      attrs: attrs,
      condition: Map.get(attrs, "condition"),
      label: Map.get(attrs, "label"),
      weight: parse_weight(Map.get(attrs, "weight")),
      fidelity: Map.get(attrs, "fidelity"),
      thread_id: Map.get(attrs, "thread_id"),
      loop_restart: truthy?(Map.get(attrs, "loop_restart", false))
    }
  end

  @spec attr(t(), String.t() | atom(), term()) :: term()
  def attr(edge, key, default \\ nil)

  def attr(%__MODULE__{attrs: attrs}, key, default) when is_atom(key) do
    attr(%__MODULE__{attrs: attrs}, Atom.to_string(key), default)
  end

  def attr(%__MODULE__{attrs: attrs}, key, default) when is_binary(key) do
    Map.get(attrs, key, default)
  end

  # -- Private helpers --

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?(_), do: false

  defp parse_weight(nil), do: nil

  defp parse_weight(val) when is_integer(val), do: val

  defp parse_weight(val) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_weight(_), do: nil
end
