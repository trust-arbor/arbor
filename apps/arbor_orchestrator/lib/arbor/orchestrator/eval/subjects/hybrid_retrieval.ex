defmodule Arbor.Orchestrator.Eval.Subjects.HybridRetrieval do
  @moduledoc """
  Compatibility wrapper for `Arbor.AI.Eval.Subjects.HybridRetrieval`.
  """

  @behaviour Arbor.Orchestrator.Eval.Subject

  @impl true
  defdelegate run(input, opts \\ []), to: Arbor.AI.Eval.Subjects.HybridRetrieval
end
