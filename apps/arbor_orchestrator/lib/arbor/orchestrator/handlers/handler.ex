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

  ## Three-Phase Protocol

  Handlers may optionally implement the three-phase protocol for structured execution:

  - `prepare/3` — validate inputs, build execution plan (no side effects)
  - `run/1` — execute the prepared plan (may have side effects)
  - `apply_result/3` — transform the result into an Outcome with context updates

  If all three callbacks are implemented, the engine will use `execute_three_phase/5`
  instead of the standard `execute/4` callback.
  """

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node

  @type idempotency_class :: :idempotent | :idempotent_with_key | :side_effecting | :read_only

  @callback execute(Node.t(), Context.t(), Graph.t(), keyword()) :: Outcome.t()
  @callback idempotency() :: idempotency_class()

  # Three-phase protocol callbacks
  @callback prepare(Node.t(), Context.t(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback run(term()) :: {:ok, term()} | {:error, term()}
  @callback apply_result(term(), Node.t(), Context.t()) :: {:ok, Outcome.t()} | {:error, term()}

  @optional_callbacks [idempotency: 0, prepare: 3, run: 1, apply_result: 3]

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

  @doc "Returns true if the handler implements all three-phase callbacks."
  @spec three_phase?(module()) :: boolean()
  def three_phase?(handler_module) do
    Code.ensure_loaded(handler_module)

    function_exported?(handler_module, :prepare, 3) and
      function_exported?(handler_module, :run, 1) and
      function_exported?(handler_module, :apply_result, 3)
  end

  @doc """
  Execute a handler using the three-phase protocol.

  Returns an Outcome. If any phase fails, returns a fail Outcome with the error reason.
  """
  @spec execute_three_phase(module(), Node.t(), Context.t(), Graph.t(), keyword()) :: Outcome.t()
  def execute_three_phase(handler_module, node, context, _graph, opts) do
    with {:ok, prepared} <- handler_module.prepare(node, context, opts),
         {:ok, result} <- handler_module.run(prepared),
         {:ok, outcome} <- handler_module.apply_result(result, node, context) do
      outcome
    else
      {:error, reason} ->
        %Outcome{
          status: :fail,
          failure_reason: format_error(reason)
        }
    end
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
