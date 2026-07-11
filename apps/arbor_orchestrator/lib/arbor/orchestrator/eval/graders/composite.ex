defmodule Arbor.Orchestrator.Eval.Graders.Composite do
  @moduledoc """
  Compatibility wrapper for `Arbor.Eval.Graders.Composite`.
  """

  @behaviour Arbor.Orchestrator.Eval.Grader

  @impl true
  defdelegate grade(actual, expected, opts \\ []), to: Arbor.Eval.Graders.Composite
end
