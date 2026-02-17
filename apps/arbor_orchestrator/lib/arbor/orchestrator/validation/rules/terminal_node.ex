defmodule Arbor.Orchestrator.Validation.Rules.TerminalNode do
  @moduledoc false
  @behaviour Arbor.Orchestrator.Validation.LintRule

  alias Arbor.Orchestrator.Validation.Diagnostic
  import Arbor.Orchestrator.Validation.Rules.Helpers, only: [find_terminal_nodes: 1]

  @impl true
  def name, do: "terminal_node"

  @impl true
  def validate(graph) do
    case length(find_terminal_nodes(graph)) do
      1 -> []
      0 -> [Diagnostic.error("terminal_node", "Pipeline must have exactly one terminal node")]
      _ -> [Diagnostic.error("terminal_node", "Pipeline has multiple terminal nodes")]
    end
  end
end
