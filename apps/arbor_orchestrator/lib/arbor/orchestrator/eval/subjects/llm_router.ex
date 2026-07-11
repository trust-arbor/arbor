defmodule Arbor.Orchestrator.Eval.Subjects.LLMRouter do
  @moduledoc """
  Compatibility wrapper for `Arbor.AI.Eval.Subjects.LLMRouter`.
  """

  @behaviour Arbor.Orchestrator.Eval.Subject

  @impl true
  defdelegate run(input, opts \\ []), to: Arbor.AI.Eval.Subjects.LLMRouter
end
