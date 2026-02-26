defmodule Arbor.Orchestrator.Handlers.BranchHandler do
  @moduledoc """
  Core handler for conditional branching in pipelines.

  Canonical type: `branch`
  Aliases: `conditional`

  The engine evaluates outgoing edge conditions; this handler
  simply marks the branch point as evaluated.
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.Outcome

  @impl true
  def execute(node, _context, _graph, _opts) do
    %Outcome{status: :success, notes: "Conditional node evaluated: #{node.id}"}
  end

  @impl true
  def idempotency, do: :idempotent
end
