defmodule Arbor.Orchestrator.Human.AutoApproveInterviewer do
  @moduledoc false

  @behaviour Arbor.Orchestrator.Human.Interviewer

  alias Arbor.Orchestrator.Human.{Answer, Question}

  @impl true
  def ask(question, opts \\ [])

  def ask(%Question{options: [first | _]}, _opts) do
    %Answer{value: first.key, selected_option: first}
  end

  def ask(%Question{}, _opts), do: %Answer{value: :skipped}
end
