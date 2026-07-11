defmodule Arbor.Orchestrator.Eval.Subjects.Passthrough do
  @moduledoc """
  Compatibility wrapper for `Arbor.Eval.Subjects.Passthrough`.
  """

  @behaviour Arbor.Orchestrator.Eval.Subject

  @impl true
  defdelegate run(input, opts), to: Arbor.Eval.Subjects.Passthrough
end
