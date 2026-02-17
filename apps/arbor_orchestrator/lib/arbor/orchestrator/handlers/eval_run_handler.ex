defmodule Arbor.Orchestrator.Handlers.EvalRunHandler do
  @moduledoc """
  Handler that runs evaluation: iterates samples, invokes subject, applies graders.

  Node attributes:
    - `subject` — subject type: "function" or module name (optional, defaults to passthrough)
    - `graders` — comma-separated grader names (required)
    - `subject_module` — module name for "function" subject (optional)
    - `subject_function` — function name for "function" subject (optional)
    - `model` — model name (optional, reads from context)
    - `provider` — provider name (optional, reads from context)

  When running inside a map handler iteration, reads model/provider from
  `map.current_item` context (expects `%{"model" => ..., "provider" => ...}`).
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  import Arbor.Orchestrator.Handlers.Helpers, only: [parse_csv: 1, maybe_add: 3]

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Eval

  @impl true
  def execute(node, context, _graph, _opts) do
    samples = Context.get(context, "eval.dataset", [])

    unless is_list(samples) and samples != [] do
      raise "eval.run requires samples in context key 'eval.dataset' — run eval.dataset first"
    end

    grader_names = parse_csv(Map.get(node.attrs, "graders", ""))

    if grader_names == [] do
      raise "eval.run requires 'graders' attribute (comma-separated grader names)"
    end

    subject = resolve_subject(node)
    {model, provider} = resolve_model_provider(node, context)

    # Pass model/provider as opts to the subject
    subject_opts =
      []
      |> maybe_add(:model, model)
      |> maybe_add(:provider, provider)

    results = Eval.run_eval(samples, subject, grader_names, subject_opts)

    passed_count = Enum.count(results, & &1["passed"])

    context_updates = %{
      "eval.results.#{node.id}" => results,
      "eval.results.#{node.id}.count" => length(results),
      "eval.results.#{node.id}.passed" => passed_count
    }

    # Propagate model/provider to downstream nodes
    context_updates =
      if model, do: Map.put(context_updates, "eval.model", model), else: context_updates

    context_updates =
      if provider,
        do: Map.put(context_updates, "eval.provider", provider),
        else: context_updates

    %Outcome{
      status: :success,
      notes: "Evaluated #{length(results)} samples: #{passed_count}/#{length(results)} passed",
      context_updates: context_updates
    }
  rescue
    e ->
      %Outcome{
        status: :fail,
        failure_reason: "eval.run error: #{Exception.message(e)}"
      }
  end

  @impl true
  def idempotency, do: :read_only

  # --- Model/provider resolution ---

  defp resolve_model_provider(node, context) do
    # Priority: node attrs > map.current_item > eval.model/eval.provider context
    model =
      Map.get(node.attrs, "model") ||
        get_from_map_item(context, "model") ||
        Context.get(context, "eval.model")

    provider =
      Map.get(node.attrs, "provider") ||
        get_from_map_item(context, "provider") ||
        Context.get(context, "eval.provider")

    {model, provider}
  end

  defp get_from_map_item(context, key) do
    case Context.get(context, "map.current_item") do
      item when is_map(item) -> Map.get(item, key) || Map.get(item, safe_to_existing_atom(key))
      item when is_binary(item) -> try_parse_json_item(item, key)
      _ -> nil
    end
  end

  defp safe_to_existing_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> str
  end

  defp try_parse_json_item(str, key) do
    case Jason.decode(str) do
      {:ok, map} when is_map(map) -> Map.get(map, key)
      _ -> nil
    end
  end

  # --- Subject resolution ---

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

end
