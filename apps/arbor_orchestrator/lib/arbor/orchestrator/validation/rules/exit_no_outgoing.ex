defmodule Arbor.Orchestrator.Validation.Rules.ExitNoOutgoing do
  @moduledoc false
  @behaviour Arbor.Orchestrator.Validation.LintRule

  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Validation.Diagnostic
  import Arbor.Orchestrator.Validation.Rules.Helpers, only: [find_terminal_nodes: 1]

  @impl true
  def name, do: "exit_no_outgoing"

  @impl true
  def validate(graph) do
    graph
    |> find_terminal_nodes()
    |> Enum.flat_map(fn terminal ->
      if Graph.outgoing_edges(graph, terminal.id) == [] do
        []
      else
        [
          Diagnostic.error("exit_no_outgoing", "Exit node must not have outgoing edges",
            node_id: terminal.id
          )
        ]
      end
    end)
  end
end
