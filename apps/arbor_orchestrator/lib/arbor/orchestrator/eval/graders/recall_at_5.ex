defmodule Arbor.Orchestrator.Eval.Graders.RecallAt5 do
  @moduledoc """
  Compatibility wrapper for `Arbor.Eval.Graders.RecallAt5`.
  """

  @behaviour Arbor.Orchestrator.Eval.Grader

  @impl true
  defdelegate grade(actual, expected, opts \\ []), to: Arbor.Eval.Graders.RecallAt5
end
