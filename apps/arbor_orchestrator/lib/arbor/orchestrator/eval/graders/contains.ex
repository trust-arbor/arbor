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

    a = if case_sensitive, do: to_string(actual), else: String.downcase(to_string(actual))
    e = if case_sensitive, do: to_string(expected), else: String.downcase(to_string(expected))

    if String.contains?(a, e) do
      %{score: 1.0, passed: true, detail: "contains match"}
    else
      %{score: 0.0, passed: false, detail: "substring not found"}
    end
  end
end
