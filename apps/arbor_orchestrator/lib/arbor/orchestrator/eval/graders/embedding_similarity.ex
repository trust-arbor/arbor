defmodule Arbor.Orchestrator.Eval.Graders.EmbeddingSimilarity do
  @moduledoc """
  Compatibility wrapper for `Arbor.AI.Eval.Graders.EmbeddingSimilarity`.
  """

  @behaviour Arbor.Orchestrator.Eval.Grader

  @impl true
  defdelegate grade(actual, expected, opts \\ []),
    to: Arbor.AI.Eval.Graders.EmbeddingSimilarity

  defdelegate cosine_similarity(a, b), to: Arbor.AI.Eval.Graders.EmbeddingSimilarity
end
