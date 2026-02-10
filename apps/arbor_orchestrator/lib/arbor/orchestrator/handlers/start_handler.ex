defmodule Arbor.Orchestrator.Handlers.StartHandler do
  @moduledoc false

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.Outcome

  @impl true
  def execute(_node, _context, _graph, _opts), do: %Outcome{status: :success}
end
