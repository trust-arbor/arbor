defmodule Arbor.Orchestrator.Handlers.BehaviourHelpers do
  @moduledoc """
  Safe invocation helpers for `Arbor.Orchestrator.Handlers.Handler` implementations.

  Provides wrapper functions that:
  - Enforce return type contracts at runtime
  - Improve Dialyzer inference via explicit @spec
  - Centralize error handling for invalid handler returns

  ## Usage

  Handlers should **never** be called directly. Always go through the wrapper:

      BehaviourHelpers.execute(handler_module, node, context, graph, opts)

  This is the Ash.BehaviourHelpers pattern adapted for the orchestrator.
  """

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.Handler

  @doc """
  Executes a handler module through the validated wrapper.

  Raises `Arbor.Orchestrator.Handlers.InvalidReturnError` if the handler
  returns a value that does not match the expected `Outcome.t()` shape.
  """
  @spec execute(module(), Node.t(), Context.t(), Graph.t(), keyword()) :: Outcome.t()
  def execute(handler_module, node, context, graph, opts \\ []) do
    result = handler_module.execute(node, context, graph, opts)

    if is_struct(result, Outcome) do
      result
    else
      raise Arbor.Orchestrator.Handlers.InvalidReturnError,
            "Handler #{inspect(handler_module)}.execute/4 must return %Outcome{}, got: #{inspect(result)}"
    end
  end

  @doc """
  Executes a handler using the three-phase protocol with validation.
  """
  @spec execute_three_phase(module(), Node.t(), Context.t(), Graph.t(), keyword()) :: Outcome.t()
  def execute_three_phase(handler_module, node, context, graph, opts \\ []) do
    # Delegate to the existing implementation in Handler, then validate
    outcome = Handler.execute_three_phase(handler_module, node, context, graph, opts)

    if is_struct(outcome, Outcome) do
      outcome
    else
      raise Arbor.Orchestrator.Handlers.InvalidReturnError,
            "Three-phase handler #{inspect(handler_module)} must return %Outcome{}"
    end
  end
end
