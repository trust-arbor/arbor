defmodule Arbor.Orchestrator.Eval.Graders.FunctionalTest do
  @moduledoc """
  Compatibility wrapper for `Arbor.Eval.Graders.FunctionalTest`.
  """

  @behaviour Arbor.Orchestrator.Eval.Grader

  @impl true
  defdelegate grade(actual, expected, opts \\ []), to: Arbor.Eval.Graders.FunctionalTest
end
