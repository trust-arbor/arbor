defmodule Arbor.Orchestrator.Eval.Graders.CodeQuality do
  @moduledoc """
  Compatibility wrapper for `Arbor.Eval.Graders.CodeQuality`.
  """

  @behaviour Arbor.Orchestrator.Eval.Grader

  @impl true
  defdelegate grade(actual, expected, opts \\ []), to: Arbor.Eval.Graders.CodeQuality
end
