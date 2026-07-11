defmodule Arbor.Orchestrator.Eval.Graders.IntentConformance do
  @moduledoc """
  Compatibility wrapper for `Arbor.AI.Eval.Graders.IntentConformance`.
  """

  @behaviour Arbor.Orchestrator.Eval.Grader

  @impl true
  defdelegate grade(actual, expected, opts \\ []),
    to: Arbor.AI.Eval.Graders.IntentConformance
end
