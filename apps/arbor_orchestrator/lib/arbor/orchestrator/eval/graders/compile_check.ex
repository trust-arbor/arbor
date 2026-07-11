defmodule Arbor.Orchestrator.Eval.Graders.CompileCheck do
  @moduledoc """
  Compatibility wrapper for `Arbor.Eval.Graders.CompileCheck`.
  """

  @behaviour Arbor.Orchestrator.Eval.Grader

  @impl true
  defdelegate grade(actual, expected, opts \\ []), to: Arbor.Eval.Graders.CompileCheck

  defdelegate extract_code(text), to: Arbor.Eval.Graders.CompileCheck
end
