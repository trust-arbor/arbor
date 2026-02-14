defmodule Arbor.Orchestrator.Eval.Graders.CodeQuality do
  @moduledoc """
  Grader that bridges to `arbor_eval` static analysis checks.

  Runs the code through Arbor.Eval.check_code/2 and scores based on
  how many checks pass. Uses runtime bridge for cross-hierarchy access.

  Options:
    - `:checks` — list of check module atoms (default: ElixirIdioms, NamingConventions)
    - `:pass_threshold` — minimum score to pass (default: 0.5)
  """

  @behaviour Arbor.Orchestrator.Eval.Grader

  alias Arbor.Orchestrator.Eval.Graders.CompileCheck

  @eval_mod Arbor.Eval

  @default_checks [
    Arbor.Eval.Checks.ElixirIdioms,
    Arbor.Eval.Checks.NamingConventions
  ]

  @impl true
  def grade(actual, _expected, opts \\ []) do
    code = CompileCheck.extract_code(to_string(actual))
    checks = Keyword.get(opts, :checks, @default_checks)
    threshold = Keyword.get(opts, :pass_threshold, 0.5)

    if Code.ensure_loaded?(@eval_mod) do
      run_checks(code, checks, threshold)
    else
      %{
        score: 0.0,
        passed: false,
        detail: "arbor_eval not available — cannot run static analysis"
      }
    end
  end

  defp run_checks(code, checks, threshold) do
    case apply(@eval_mod, :check_code, [code, [evals: checks]]) do
      {:ok, results} ->
        total = length(results)

        if total == 0 do
          %{score: 1.0, passed: true, detail: "no checks configured"}
        else
          passed_count = Enum.count(results, & &1.passed)
          score = passed_count / total

          violations =
            results
            |> Enum.reject(& &1.passed)
            |> Enum.flat_map(fn r -> r.violations end)

          violation_summary =
            if violations == [] do
              "all checks passed"
            else
              count = length(violations)
              samples = violations |> Enum.take(3) |> Enum.map(& &1.message) |> Enum.join("; ")
              "#{count} violation(s): #{samples}"
            end

          %{
            score: score,
            passed: score >= threshold,
            detail: "#{passed_count}/#{total} checks passed. #{violation_summary}"
          }
        end

      {:error, reason} ->
        %{score: 0.0, passed: false, detail: "check_code failed: #{inspect(reason)}"}
    end
  rescue
    e ->
      %{score: 0.0, passed: false, detail: "error: #{Exception.message(e)}"}
  catch
    :exit, reason ->
      %{score: 0.0, passed: false, detail: "process unavailable: #{inspect(reason)}"}
  end
end
