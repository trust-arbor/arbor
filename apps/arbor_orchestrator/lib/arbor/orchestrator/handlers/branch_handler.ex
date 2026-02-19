defmodule Arbor.Orchestrator.Handlers.BranchHandler do
  @moduledoc """
  Core handler for conditional branching in pipelines.

  Canonical type: `branch`
  Aliases: `conditional`

  Delegates to ConditionalHandler — same logic, canonical name.
  The engine evaluates outgoing edge conditions; this handler
  simply marks the branch point as evaluated.
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Handlers.ConditionalHandler

  @impl true
  defdelegate execute(node, context, graph, opts), to: ConditionalHandler

  @impl true
  def idempotency, do: :idempotent
end
