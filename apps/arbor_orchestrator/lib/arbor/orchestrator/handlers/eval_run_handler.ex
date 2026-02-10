defmodule Arbor.Orchestrator.Handlers.EvalRunHandler do
  @moduledoc """
  Handler that runs evaluation: iterates samples, invokes subject, applies graders.

  Node attributes:
    - `subject` — subject type: "function" or module name (optional, defaults to passthrough)
    - `graders` — comma-separated grader names (required)
    - `subject_module` — module name for "function" subject (optional)
    - `subject_function` — function name for "function" subject (optional)
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Eval

  @impl true
  def execute(node, context, _graph, _opts) do
    try do
      samples = Context.get(context, "eval.dataset", [])

      unless is_list(samples) and samples != [] do
        raise "eval.run requires samples in context key 'eval.dataset' — run eval.dataset first"
      end

      grader_names = parse_csv(Map.get(node.attrs, "graders", ""))

      if grader_names == [] do
        raise "eval.run requires 'graders' attribute (comma-separated grader names)"
      end

      subject = resolve_subject(node)
      results = Eval.run_eval(samples, subject, grader_names)

      passed_count = Enum.count(results, & &1["passed"])

      %Outcome{
        status: :success,
        notes: "Evaluated #{length(results)} samples: #{passed_count}/#{length(results)} passed",
        context_updates: %{
          "eval.results.#{node.id}" => results,
          "eval.results.#{node.id}.count" => length(results),
          "eval.results.#{node.id}.passed" => passed_count
        }
      }
    rescue
      e ->
        %Outcome{
          status: :fail,
          failure_reason: "eval.run error: #{Exception.message(e)}"
        }
    end
  end

  @impl true
  def idempotency, do: :read_only

  defp resolve_subject(node) do
    case Map.get(node.attrs, "subject") do
      nil -> Arbor.Orchestrator.Eval.Subjects.Passthrough
      "function" -> resolve_function_subject(node)
      module_name -> resolve_module(module_name)
    end
  end

  defp resolve_function_subject(node) do
    mod = Map.get(node.attrs, "subject_module")
    fun = Map.get(node.attrs, "subject_function", "run")

    if mod do
      # Return an anonymous module-like struct that implements run/2
      # by delegating to apply(mod, fun, [input])
      module = resolve_module(mod)

      if function_exported?(module, String.to_existing_atom(fun), 1) do
        module
      else
        Arbor.Orchestrator.Eval.Subjects.Passthrough
      end
    else
      Arbor.Orchestrator.Eval.Subjects.Passthrough
    end
  end

  defp resolve_module(name) when is_binary(name) do
    module = Module.concat([name])
    Code.ensure_loaded(module)
    module
  rescue
    _ -> Arbor.Orchestrator.Eval.Subjects.Passthrough
  end

  defp parse_csv(nil), do: []
  defp parse_csv(""), do: []

  defp parse_csv(str) do
    str |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end
end
