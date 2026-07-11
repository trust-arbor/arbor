defmodule Arbor.Eval.Graders.ExactMatch do
  @moduledoc """
  Grader that checks for exact string equality.

  ## Options

  - `:case_sensitive` - boolean, defaults to `true`
  - `:trim` - boolean, defaults to `false`
  """

  @behaviour Arbor.Eval.Grader

  @impl true
  def grade(actual, expected, opts \\ []) do
    case_sensitive = Keyword.get(opts, :case_sensitive, true)
    trim = Keyword.get(opts, :trim, false)

    actual = normalize(to_string(actual), case_sensitive, trim)
    expected = normalize(to_string(expected), case_sensitive, trim)

    if actual == expected do
      %{score: 1.0, passed: true, detail: "exact match"}
    else
      %{score: 0.0, passed: false, detail: "no match"}
    end
  end

  defp normalize(value, case_sensitive, trim) do
    value = if trim, do: String.trim(value), else: value
    if case_sensitive, do: value, else: String.downcase(value)
  end
end
