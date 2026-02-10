defmodule Arbor.Orchestrator.Handlers.Handler do
  @moduledoc false

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node

  @callback execute(Node.t(), Context.t(), Graph.t(), keyword()) :: Outcome.t()
end
