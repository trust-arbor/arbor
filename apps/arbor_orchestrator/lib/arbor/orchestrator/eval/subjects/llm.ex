defmodule Arbor.Orchestrator.Eval.Subjects.LLM do
  @moduledoc """
  Compatibility wrapper for `Arbor.LLM.Eval.Subject`.
  """

  @behaviour Arbor.Orchestrator.Eval.Subject

  @impl true
  defdelegate run(input, opts \\ []), to: Arbor.LLM.Eval.Subject
end
