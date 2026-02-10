defmodule Arbor.Orchestrator.Human.Interviewer do
  @moduledoc false

  alias Arbor.Orchestrator.Human.{Answer, Question}

  @callback ask(Question.t(), keyword()) :: Answer.t()
end
