defmodule Arbor.Orchestrator.Eval.Grader do
  @moduledoc """
  Behaviour for evaluation graders.

  A grader compares actual output against expected output and produces
  a score, pass/fail decision, and detail string.
  """

  @type result :: %{
          score: float(),
          passed: boolean(),
          detail: String.t()
        }

  @callback grade(actual :: term(), expected :: term(), opts :: keyword()) :: result()
end
