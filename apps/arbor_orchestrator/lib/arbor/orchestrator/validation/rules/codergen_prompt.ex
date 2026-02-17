defmodule Arbor.Orchestrator.Validation.Rules.CodergenPrompt do
  @moduledoc false
  @behaviour Arbor.Orchestrator.Validation.LintRule

  alias Arbor.Orchestrator.Validation.Diagnostic

  @impl true
  def name, do: "codergen_prompt"

  @impl true
  def validate(graph) do
    graph.nodes
    |> Map.values()
    |> Enum.flat_map(fn node ->
      shape = Map.get(node.attrs, "shape", "box")
      node_type = Map.get(node.attrs, "type")
      prompt = Map.get(node.attrs, "prompt", "")

      is_codergen =
        node_type == "codergen" or
          (node_type in [nil, ""] and shape == "box")

      if is_codergen and to_string(prompt) == "" do
        [
          Diagnostic.warning("codergen_prompt", "Codergen node is missing prompt",
            node_id: node.id
          )
        ]
      else
        []
      end
    end)
  end
end
