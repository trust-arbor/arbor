defmodule Arbor.Orchestrator.Eval.Graders.RegexMatch do
  @moduledoc """
  Compatibility wrapper for `Arbor.Eval.Graders.RegexMatch`.
  """

  @behaviour Arbor.Orchestrator.Eval.Grader

  @impl true
  defdelegate grade(actual, expected, opts \\ []), to: Arbor.Eval.Graders.RegexMatch
end
