defmodule Arbor.Orchestrator.Eval.Graders.ExactMatch do
  @moduledoc """
  Compatibility wrapper for `Arbor.Eval.Graders.ExactMatch`.
  """

  @behaviour Arbor.Orchestrator.Eval.Grader

  @impl true
  defdelegate grade(actual, expected, opts \\ []), to: Arbor.Eval.Graders.ExactMatch
end
