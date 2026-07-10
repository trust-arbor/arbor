defmodule Arbor.Orchestrator.Handlers.GateHandler do
  @moduledoc """
  Core handler for pass/fail governance gates.

  Canonical type: `gate`
  Aliases: `output.validate`, `pipeline.validate`

  Gates are pure validation checkpoints — they pass or fail but don't
  route (use `branch` for routing decisions). A gate blocks pipeline
  progression if its predicate fails.

  Dispatches by `predicate` attribute:
    - `"output_valid"` (default) — delegates to OutputValidateHandler
    - `"pipeline_valid"` — delegates to PipelineValidateHandler
    - `"budget_ok"` — checks budget status from context
    - `"expression"` — evaluates a simple context expression

  ## Node Attributes

    - `predicate` — gate predicate: "output_valid" (default),
      "pipeline_valid", "budget_ok", "expression"
    - `expression` — for predicate="expression": context key to check for truthiness
    - All attributes from the delegated handler are supported
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Context, Outcome, RunAuthorization}

  alias Arbor.Orchestrator.Handlers.{
    OutputValidateHandler,
    PipelineValidateHandler
  }

  @impl true
  def execute(node, context, graph, opts) do
    predicate = Map.get(node.attrs, "predicate", "output_valid")

    with {:ok, [{slot, module}]} <- execution_delegates(node),
         :ok <-
           RunAuthorization.verify_execution_module(
             Keyword.get(opts, :run_authorization),
             node,
             slot,
             module
           ) do
      dispatch(predicate, module, node, context, graph, opts)
    else
      {:error, reason} ->
        %Outcome{
          status: :fail,
          failure_reason: "Gate delegate binding rejected for node #{node.id}: #{inspect(reason)}"
        }
    end
  end

  @impl true
  def idempotency, do: :read_only

  @doc false
  def execution_delegates(node) do
    predicate = Map.get(node.attrs, "predicate", "output_valid")

    module =
      case predicate do
        "output_valid" -> OutputValidateHandler
        "pipeline_valid" -> PipelineValidateHandler
        "budget_ok" -> nil
        "expression" -> nil
        _unknown -> OutputValidateHandler
      end

    {:ok, [{"gate:#{predicate}", module}]}
  end

  defp dispatch("output_valid", module, node, context, graph, opts),
    do: module.execute(node, context, graph, opts)

  defp dispatch("pipeline_valid", module, node, context, graph, opts),
    do: module.execute(node, context, graph, opts)

  defp dispatch("budget_ok", nil, node, context, _graph, _opts), do: check_budget(node, context)

  defp dispatch("expression", nil, node, context, _graph, _opts),
    do: check_expression(node, context)

  defp dispatch(_unknown, module, node, context, graph, opts),
    do: module.execute(node, context, graph, opts)

  defp check_budget(node, context) do
    budget_status = Context.get(context, "budget_status", "normal")

    if budget_status in ["normal", "low"] do
      %Outcome{
        status: :success,
        notes: "Budget gate passed: #{budget_status}",
        context_updates: %{"gate.#{node.id}.passed" => true}
      }
    else
      %Outcome{
        status: :fail,
        failure_reason: "Budget gate failed: status=#{budget_status}",
        context_updates: %{"gate.#{node.id}.passed" => false}
      }
    end
  end

  defp check_expression(node, context) do
    expression = Map.get(node.attrs, "expression")

    unless expression do
      raise "gate with predicate=expression requires 'expression' attribute"
    end

    value = Context.get(context, expression)

    if truthy?(value) do
      %Outcome{
        status: :success,
        notes: "Expression gate passed: #{expression}=#{inspect(value)}",
        context_updates: %{"gate.#{node.id}.passed" => true}
      }
    else
      %Outcome{
        status: :fail,
        failure_reason: "Expression gate failed: #{expression}=#{inspect(value)}",
        context_updates: %{"gate.#{node.id}.passed" => false}
      }
    end
  rescue
    e ->
      %Outcome{
        status: :fail,
        failure_reason: "gate expression error: #{Exception.message(e)}"
      }
  end

  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?("false"), do: false
  defp truthy?(""), do: false
  defp truthy?(0), do: false
  defp truthy?(_), do: true
end
