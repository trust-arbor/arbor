defmodule Arbor.Eval.Graders.FunctionalTest do
  @moduledoc """
  Functional grader placeholder for an isolated evaluator.

  Eval subjects and assertions are untrusted model or dataset text. Executing
  either in the kernel VM would grant them the Arbor user's filesystem, process,
  network, and code-loading authority. Until a separately isolated evaluator is
  wired in, this grader fails closed without compiling or evaluating any input.
  """

  @behaviour Arbor.Eval.Grader

  @impl true
  def grade(_actual, _expected, _opts \\ []) do
    %{
      score: 0.0,
      passed: false,
      detail: "functional execution disabled: isolated evaluator required"
    }
  end
end
