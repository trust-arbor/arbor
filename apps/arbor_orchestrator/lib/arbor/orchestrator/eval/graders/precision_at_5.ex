defmodule Arbor.Orchestrator.Eval.Graders.PrecisionAt5 do
  @moduledoc """
  Precision@5 — top-5 hit rate against `expected.matches`. Thin wrapper over PrecisionAtK with k=5.
  """

  @behaviour Arbor.Orchestrator.Eval.Grader

  alias Arbor.Orchestrator.Eval.Graders.PrecisionAtK

  @impl true
  def grade(actual, expected, opts \\ []) do
    PrecisionAtK.grade(actual, expected, Keyword.put(opts, :k, 5))
  end
end
