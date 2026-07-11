defmodule Arbor.Orchestrator.Eval.Graders.Contains do
  @moduledoc """
  Compatibility wrapper for `Arbor.Eval.Graders.Contains`.
  """

  @behaviour Arbor.Orchestrator.Eval.Grader

  @impl true
  defdelegate grade(actual, expected, opts \\ []), to: Arbor.Eval.Graders.Contains
end
