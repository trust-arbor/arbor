defmodule Arbor.Orchestrator.Eval.Graders.Contains do
  @moduledoc """
  Grader that checks if expected is a substring of actual.

  Options:
    - `:case_sensitive` — boolean, default true
  """

  @behaviour Arbor.Orchestrator.Eval.Grader

  @impl true
  def grade(actual, expected, opts \\ []) do
    case_sensitive = Keyword.get(opts, :case_sensitive, true)
    keywords = extract_keywords(expected)

    a = if case_sensitive, do: to_string(actual), else: String.downcase(to_string(actual))

    results =
      Enum.map(keywords, fn kw ->
        e = if case_sensitive, do: kw, else: String.downcase(kw)
        {kw, String.contains?(a, e)}
      end)

    found = Enum.count(results, fn {_, hit} -> hit end)
    total = length(results)
    score = if total > 0, do: found / total, else: 1.0
    missing = results |> Enum.reject(fn {_, hit} -> hit end) |> Enum.map(&elem(&1, 0))

    if missing == [] do
      %{score: 1.0, passed: true, detail: "all #{total} keywords found"}
    else
      %{score: score, passed: false, detail: "missing: #{Enum.join(missing, ", ")}"}
    end
  end

  defp extract_keywords(expected) when is_map(expected) do
    case Map.get(expected, "contains") || Map.get(expected, :contains) do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      nil -> [inspect(expected)]
    end
  end

  defp extract_keywords(expected) when is_list(expected), do: Enum.map(expected, &to_string/1)
  defp extract_keywords(expected), do: [to_string(expected)]
end
