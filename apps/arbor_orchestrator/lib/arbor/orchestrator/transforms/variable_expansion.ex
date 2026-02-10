defmodule Arbor.Orchestrator.Transforms.VariableExpansion do
  @moduledoc """
  Expands simple prompt variables from graph attrs into node attrs.

  Currently supported:
  - `$goal` -> graph attr `goal`
  """

  alias Arbor.Orchestrator.Graph

  @spec apply(Graph.t()) :: Graph.t()
  def apply(%Graph{} = graph) do
    goal = Map.get(graph.attrs, "goal", "")

    nodes =
      graph.nodes
      |> Enum.map(fn {id, node} ->
        prompt = Map.get(node.attrs, "prompt")

        attrs =
          if is_binary(prompt) and String.contains?(prompt, "$goal") do
            Map.put(node.attrs, "prompt", String.replace(prompt, "$goal", to_string(goal)))
          else
            node.attrs
          end

        {id, %{node | attrs: attrs}}
      end)
      |> Map.new()

    %{graph | nodes: nodes}
  end
end
