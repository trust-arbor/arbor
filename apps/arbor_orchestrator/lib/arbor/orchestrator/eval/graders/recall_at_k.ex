defmodule Arbor.Orchestrator.Eval.Graders.RecallAtK do
  @moduledoc """
  Compatibility wrapper for `Arbor.Eval.Graders.RecallAtK`.
  """

  @behaviour Arbor.Orchestrator.Eval.Grader

  @impl true
  defdelegate grade(actual, expected, opts \\ []), to: Arbor.Eval.Graders.RecallAtK
end
