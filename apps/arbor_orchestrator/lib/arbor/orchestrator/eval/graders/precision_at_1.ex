defmodule Arbor.Orchestrator.Eval.Graders.PrecisionAt1 do
  @moduledoc """
  Precision@1 — top-1 must match `expected.primary`. Thin wrapper over PrecisionAtK with k=1.
  """

  @behaviour Arbor.Orchestrator.Eval.Grader

  alias Arbor.Orchestrator.Eval.Graders.PrecisionAtK

  @impl true
  def grade(actual, expected, opts \\ []) do
    PrecisionAtK.grade(actual, expected, Keyword.put(opts, :k, 1))
  end
end
