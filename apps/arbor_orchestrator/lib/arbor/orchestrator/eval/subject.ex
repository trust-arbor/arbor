defmodule Arbor.Orchestrator.Eval.Subject do
  @moduledoc """
  Behaviour for evaluation subjects.

  A subject takes an input and produces an output that will be graded.
  """

  @callback run(input :: term(), opts :: keyword()) :: {:ok, term()} | {:error, term()}
end
