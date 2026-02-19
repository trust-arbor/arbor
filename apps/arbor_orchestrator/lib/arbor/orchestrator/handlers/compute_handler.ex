defmodule Arbor.Orchestrator.Handlers.ComputeHandler do
  @moduledoc """
  Core handler for computation nodes — LLM calls, routing, A/B tests.

  Canonical type: `compute`
  Aliases: `codergen`, `routing.select`, `prompt.ab_test`, `drift_detect`,
           `retry.escalate`, `eval.run`, `eval.aggregate`

  Dispatches by `purpose` attribute:
    - `"llm"` (default) — delegates to CodergenHandler
    - `"routing"` — delegates to RoutingHandler
    - `"ab_test"` — delegates to PromptAbTestHandler
    - `"drift_detect"` — delegates to DriftDetectHandler
    - `"retry_escalate"` — delegates to RetryEscalateHandler
    - `"eval_run"` — delegates to EvalRunHandler
    - `"eval_aggregate"` — delegates to EvalAggregateHandler

  ## Node Attributes

    - `purpose` — computation purpose (default: "llm")
    - All attributes from the delegated handler are supported
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.Outcome
  alias Arbor.Orchestrator.Handlers.CodergenHandler

  @impl true
  def execute(node, context, graph, opts) do
    purpose = Map.get(node.attrs, "purpose", "llm")
    dispatch(purpose, node, context, graph, opts)
  end

  @impl true
  def idempotency, do: :idempotent_with_key

  defp dispatch("llm", node, context, graph, opts) do
    CodergenHandler.execute(node, context, graph, opts)
  end

  defp dispatch("routing", node, context, graph, opts) do
    delegate_to(Arbor.Orchestrator.Handlers.RoutingHandler, node, context, graph, opts)
  end

  defp dispatch("ab_test", node, context, graph, opts) do
    delegate_to(Arbor.Orchestrator.Handlers.PromptAbTestHandler, node, context, graph, opts)
  end

  defp dispatch("drift_detect", node, context, graph, opts) do
    delegate_to(Arbor.Orchestrator.Handlers.DriftDetectHandler, node, context, graph, opts)
  end

  defp dispatch("retry_escalate", node, context, graph, opts) do
    delegate_to(Arbor.Orchestrator.Handlers.RetryEscalateHandler, node, context, graph, opts)
  end

  defp dispatch("eval_run", node, context, graph, opts) do
    delegate_to(Arbor.Orchestrator.Handlers.EvalRunHandler, node, context, graph, opts)
  end

  defp dispatch("eval_aggregate", node, context, graph, opts) do
    delegate_to(Arbor.Orchestrator.Handlers.EvalAggregateHandler, node, context, graph, opts)
  end

  defp dispatch(unknown, node, _context, _graph, _opts) do
    %Outcome{
      status: :fail,
      failure_reason: "Unknown compute purpose '#{unknown}' for node #{node.id}"
    }
  end

  defp delegate_to(module, node, context, graph, opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :execute, 4) do
      module.execute(node, context, graph, opts)
    else
      %Outcome{
        status: :fail,
        failure_reason: "Handler module #{inspect(module)} not available"
      }
    end
  end
end
