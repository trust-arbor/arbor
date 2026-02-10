defmodule Arbor.Orchestrator.Eval.Subjects.Passthrough do
  @moduledoc """
  Subject that returns the input unchanged. Used as a default
  when no subject is configured, or for testing graders directly.
  """

  @behaviour Arbor.Orchestrator.Eval.Subject

  @impl true
  def run(input, _opts), do: {:ok, input}
end
