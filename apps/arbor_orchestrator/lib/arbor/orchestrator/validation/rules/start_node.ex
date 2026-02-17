defmodule Arbor.Orchestrator.Validation.Rules.StartNode do
  @moduledoc false
  @behaviour Arbor.Orchestrator.Validation.LintRule

  alias Arbor.Orchestrator.Validation.Diagnostic
  import Arbor.Orchestrator.Validation.Rules.Helpers, only: [find_start_nodes: 1]

  @impl true
  def name, do: "start_node"

  @impl true
  def validate(graph) do
    case length(find_start_nodes(graph)) do
      1 -> []
      0 -> [Diagnostic.error("start_node", "Pipeline must have exactly one start node")]
      _ -> [Diagnostic.error("start_node", "Pipeline has multiple start nodes")]
    end
  end
end
