defmodule Arbor.Eval.Grader do
  @moduledoc """
  Behaviour for evaluation graders.

  A grader compares actual and expected values and returns a score, pass/fail
  decision, and human-readable detail.
  """

  @type result :: %{
          score: float(),
          passed: boolean(),
          detail: String.t()
        }

  @callback grade(actual :: term(), expected :: term(), opts :: keyword()) :: result()
end
