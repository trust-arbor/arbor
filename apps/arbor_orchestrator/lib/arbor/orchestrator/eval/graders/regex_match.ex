defmodule Arbor.Orchestrator.Eval.Graders.RegexMatch do
  @moduledoc """
  Grader that checks if actual output matches a regex pattern.

  The `expected` value is used as the regex pattern.

  Options:
    - `:flags` — regex flags string, e.g. "i" for case-insensitive
  """

  @behaviour Arbor.Orchestrator.Eval.Grader

  @impl true
  def grade(actual, expected, opts \\ []) do
    flags = Keyword.get(opts, :flags, "")
    pattern = to_string(expected)

    # Eval grader: compiles regex from eval spec's expected pattern
    # credo:disable-for-next-line Credo.Check.Security.UnsafeRegexCompile
    case Regex.compile(pattern, flags) do
      {:ok, regex} ->
        if Regex.match?(regex, to_string(actual)) do
          %{score: 1.0, passed: true, detail: "regex match"}
        else
          %{score: 0.0, passed: false, detail: "pattern not matched"}
        end

      {:error, reason} ->
        %{score: 0.0, passed: false, detail: "invalid regex: #{inspect(reason)}"}
    end
  end
end
