defmodule Arbor.Orchestrator.Handlers.FanInHandler do
  @moduledoc false

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Context, Outcome}

  @impl true
  def execute(node, context, _graph, opts) do
    results = normalize_results(Context.get(context, "parallel.results", []))

    cond do
      results == [] ->
        %Outcome{status: :fail, failure_reason: "No parallel results to evaluate"}

      Enum.all?(results, &(&1.status == :fail)) ->
        %Outcome{status: :fail, failure_reason: "All parallel candidates failed"}

      true ->
        best = choose_best(results, node, opts)

        %Outcome{
          status: :success,
          context_updates: %{
            "parallel.fan_in.best_id" => best.id,
            "parallel.fan_in.best_outcome" => to_string(best.status),
            "parallel.fan_in.best_score" => best.score
          },
          notes: "Selected best candidate: #{best.id}"
        }
    end
  end

  @impl true
  def idempotency, do: :side_effecting

  defp choose_best(results, node, opts) do
    prompt = Map.get(node.attrs, "prompt", "")

    if is_binary(prompt) and String.trim(prompt) != "" do
      case evaluate_with_prompt(prompt, results, opts) do
        nil -> heuristic_select(results)
        selected -> selected
      end
    else
      heuristic_select(results)
    end
  end

  defp heuristic_select(results) do
    Enum.sort_by(results, fn result ->
      {outcome_rank(result.status), -result.score, result.id}
    end)
    |> List.first()
  end

  defp evaluate_with_prompt(prompt, results, opts) do
    case Keyword.get(opts, :fan_in_evaluator) do
      fun when is_function(fun, 2) ->
        normalize_selected(fun.(prompt, results), results)

      fun when is_function(fun, 3) ->
        normalize_selected(fun.(prompt, results, opts), results)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp normalize_selected(nil, _results), do: nil

  defp normalize_selected(%{} = selected, _results),
    do: normalize_result(selected)

  defp normalize_selected(selected_id, results) when is_binary(selected_id) do
    Enum.find(results, &(&1.id == selected_id))
  end

  defp normalize_selected(_, _results), do: nil

  defp outcome_rank(:success), do: 0
  defp outcome_rank(:partial_success), do: 1
  defp outcome_rank(:retry), do: 2
  defp outcome_rank(:fail), do: 3
  defp outcome_rank(:skipped), do: 4
  defp outcome_rank(_), do: 10

  defp normalize_results(results) when is_list(results),
    do: Enum.map(results, &normalize_result/1)

  defp normalize_results(_), do: []

  defp normalize_result(%{} = result) do
    %{
      id: to_string(Map.get(result, "id") || Map.get(result, :id) || "unknown"),
      status: normalize_status(Map.get(result, "status") || Map.get(result, :status)),
      score: normalize_score(Map.get(result, "score") || Map.get(result, :score))
    }
  end

  defp normalize_result(_), do: %{id: "unknown", status: :fail, score: 0.0}

  defp normalize_status(value) when is_atom(value), do: value

  defp normalize_status(value) when is_binary(value) do
    case String.downcase(value) do
      "success" -> :success
      "partial_success" -> :partial_success
      "retry" -> :retry
      "fail" -> :fail
      "skipped" -> :skipped
      _ -> :fail
    end
  end

  defp normalize_status(_), do: :fail

  defp normalize_score(value) when is_float(value), do: value
  defp normalize_score(value) when is_integer(value), do: value / 1

  defp normalize_score(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} -> parsed
      :error -> 0.0
    end
  end

  defp normalize_score(_), do: 0.0
end
