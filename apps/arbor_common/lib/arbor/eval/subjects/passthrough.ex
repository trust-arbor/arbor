defmodule Arbor.Eval.Subjects.Passthrough do
  @moduledoc """
  Evaluation subject that returns its input unchanged.
  """

  @behaviour Arbor.Eval.Subject

  @impl true
  def run(input, _opts), do: {:ok, input}
end
