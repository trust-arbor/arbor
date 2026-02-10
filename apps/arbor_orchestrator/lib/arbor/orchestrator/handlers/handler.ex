defmodule Arbor.Orchestrator.Handlers.Handler do
  @moduledoc """
  Behaviour for pipeline node handlers.

  ## Idempotency Classes

  Handlers declare their idempotency class via `idempotency/0`:

  - `:idempotent` — safe to replay without side effects (e.g., start, exit, conditional)
  - `:idempotent_with_key` — safe to replay if the same input key is used (e.g., file.write with same path)
  - `:side_effecting` — has external side effects, needs compensation on replay (e.g., tool, pipeline.run)
  - `:read_only` — reads external state but doesn't modify it (e.g., pipeline.validate)

  This is used by the engine for safe checkpoint resume and crash recovery.
  """

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node

  @type idempotency_class :: :idempotent | :idempotent_with_key | :side_effecting | :read_only

  @callback execute(Node.t(), Context.t(), Graph.t(), keyword()) :: Outcome.t()
  @callback idempotency() :: idempotency_class()

  @optional_callbacks [idempotency: 0]

  @doc "Returns the idempotency class for a handler module, defaulting to :side_effecting."
  @spec idempotency_of(module()) :: idempotency_class()
  def idempotency_of(handler_module) do
    Code.ensure_loaded(handler_module)

    if function_exported?(handler_module, :idempotency, 0) do
      handler_module.idempotency()
    else
      :side_effecting
    end
  end
end
