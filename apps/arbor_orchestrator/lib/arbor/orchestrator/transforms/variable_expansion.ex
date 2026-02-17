defmodule Arbor.Orchestrator.Transforms.VariableExpansion do
  @moduledoc """
  Expands `$variable` references in node prompts and labels from graph attrs.

  Built-in variables:
  - `$goal`  → graph attr `"goal"`
  - `$label` → graph attr `"label"` (graph display name)
  - `$id`    → graph id

  Any other `$name` is expanded from `graph.attrs["name"]` if present.
  Unresolved variables are left as-is.
  """

  alias Arbor.Orchestrator.Graph

  @expandable_fields ~w(prompt label)

  @spec apply(Graph.t()) :: Graph.t()
  def apply(%Graph{} = graph) do
    variables = build_variables(graph)

    if map_size(variables) == 0 do
      graph
    else
      nodes =
        graph.nodes
        |> Enum.map(fn {id, node} -> {id, expand_node(node, variables)} end)
        |> Map.new()

      %{graph | nodes: nodes}
    end
  end

  defp build_variables(%Graph{} = graph) do
    base = %{
      "goal" => Map.get(graph.attrs, "goal", ""),
      "label" => Map.get(graph.attrs, "label", ""),
      "id" => graph.id || ""
    }

    # Merge all graph attrs as potential variables (base takes precedence)
    graph.attrs
    |> Map.merge(base)
    |> Enum.reject(fn {_k, v} -> not is_binary(v) and not is_number(v) end)
    |> Map.new(fn {k, v} -> {k, to_string(v)} end)
  end

  defp expand_node(node, variables) do
    Enum.reduce(@expandable_fields, node, fn field, acc ->
      case get_expandable(acc, field) do
        nil -> acc
        value -> put_expandable(acc, field, expand_string(value, variables))
      end
    end)
  end

  defp get_expandable(node, field) do
    # Check typed field first, then overflow attrs
    Map.get(node, String.to_existing_atom(field)) || Map.get(node.attrs, field)
  end

  defp put_expandable(node, field, value) do
    atom_field = String.to_existing_atom(field)

    node
    |> Map.put(atom_field, value)
    |> then(fn n ->
      if Map.has_key?(n.attrs, field) do
        %{n | attrs: Map.put(n.attrs, field, value)}
      else
        n
      end
    end)
  end

  defp expand_string(str, variables) when is_binary(str) do
    Regex.replace(~r/\$([a-zA-Z_][a-zA-Z0-9_]*)/, str, fn _match, name ->
      Map.get(variables, name, "$#{name}")
    end)
  end
end
