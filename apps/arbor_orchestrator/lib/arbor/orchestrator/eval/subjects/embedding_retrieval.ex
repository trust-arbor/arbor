defmodule Arbor.Orchestrator.Eval.Subjects.EmbeddingRetrieval do
  @moduledoc """
  Compatibility wrapper for `Arbor.AI.Eval.Subjects.EmbeddingRetrieval`.
  """

  @behaviour Arbor.Orchestrator.Eval.Subject

  @impl true
  defdelegate run(input, opts \\ []), to: Arbor.AI.Eval.Subjects.EmbeddingRetrieval
end
