defmodule Arbor.Orchestrator.Eval.Graders.PrecisionAt1 do
  @moduledoc """
  Compatibility wrapper for `Arbor.Eval.Graders.PrecisionAt1`.
  """

  @behaviour Arbor.Orchestrator.Eval.Grader

  @impl true
  defdelegate grade(actual, expected, opts \\ []), to: Arbor.Eval.Graders.PrecisionAt1
end
