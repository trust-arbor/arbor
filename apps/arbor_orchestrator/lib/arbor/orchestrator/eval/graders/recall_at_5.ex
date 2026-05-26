defmodule Arbor.Orchestrator.Eval.Graders.RecallAt5 do
  @moduledoc """
  Recall@5 — fraction of `expected.matches` found in top-5. Thin wrapper over RecallAtK with k=5.
  """

  @behaviour Arbor.Orchestrator.Eval.Grader

  alias Arbor.Orchestrator.Eval.Graders.RecallAtK

  @impl true
  def grade(actual, expected, opts \\ []) do
    RecallAtK.grade(actual, expected, Keyword.put(opts, :k, 5))
  end
end
