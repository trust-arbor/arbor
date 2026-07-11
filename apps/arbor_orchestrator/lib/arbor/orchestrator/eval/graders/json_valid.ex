defmodule Arbor.Orchestrator.Eval.Graders.JsonValid do
  @moduledoc """
  Compatibility wrapper for `Arbor.Eval.Graders.JsonValid`.
  """

  @behaviour Arbor.Orchestrator.Eval.Grader

  @impl true
  defdelegate grade(actual, expected, opts \\ []), to: Arbor.Eval.Graders.JsonValid
end
