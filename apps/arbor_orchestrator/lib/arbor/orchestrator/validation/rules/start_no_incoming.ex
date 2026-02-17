defmodule Arbor.Orchestrator.Validation.Rules.StartNoIncoming do
  @moduledoc false
  @behaviour Arbor.Orchestrator.Validation.LintRule

  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Validation.Diagnostic
  import Arbor.Orchestrator.Validation.Rules.Helpers, only: [find_start_nodes: 1]

  @impl true
  def name, do: "start_no_incoming"

  @impl true
  def validate(graph) do
    graph
    |> find_start_nodes()
    |> Enum.flat_map(fn start ->
      if Graph.incoming_edges(graph, start.id) == [] do
        []
      else
        [
          Diagnostic.error("start_no_incoming", "Start node must not have incoming edges",
            node_id: start.id
          )
        ]
      end
    end)
  end
end
