defmodule Arbor.Orchestrator.Handlers.ConditionalHandler do
  @moduledoc false

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.Outcome

  @impl true
  def execute(node, _context, _graph, _opts) do
    %Outcome{status: :success, notes: "Conditional node evaluated: #{node.id}"}
  end

  @impl true
  def idempotency, do: :idempotent
end
