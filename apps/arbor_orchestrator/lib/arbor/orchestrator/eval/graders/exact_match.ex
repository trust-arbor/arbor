defmodule Arbor.Orchestrator.Eval.Graders.ExactMatch do
  @moduledoc """
  Grader that checks for exact string equality.

  Options:
    - `:case_sensitive` — boolean, default true
    - `:trim` — boolean, default false
  """

  @behaviour Arbor.Orchestrator.Eval.Grader

  @impl true
  def grade(actual, expected, opts \\ []) do
    case_sensitive = Keyword.get(opts, :case_sensitive, true)
    trim = Keyword.get(opts, :trim, false)

    a = normalize(to_string(actual), case_sensitive, trim)
    e = normalize(to_string(expected), case_sensitive, trim)

    if a == e do
      %{score: 1.0, passed: true, detail: "exact match"}
    else
      %{score: 0.0, passed: false, detail: "no match"}
    end
  end

  defp normalize(str, case_sensitive, trim) do
    str = if trim, do: String.trim(str), else: str
    if case_sensitive, do: str, else: String.downcase(str)
  end
end
