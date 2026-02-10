defmodule Arbor.Orchestrator.Human.QueueInterviewer do
  @moduledoc false

  @behaviour Arbor.Orchestrator.Human.Interviewer

  alias Arbor.Orchestrator.Human.{Answer, Question}

  @impl true
  def ask(%Question{stage: stage}, opts \\ []) do
    stage_answers = Keyword.get(opts, :answers_by_stage, %{})
    queue_answers = Keyword.get(opts, :answers, [])

    staged =
      case Map.get(stage_answers, stage) do
        nil -> []
        value when is_list(value) -> value
        value -> [value]
      end

    answer = List.first(staged ++ queue_answers)

    if answer == nil and Keyword.get(opts, :return_timeout_when_empty, false) do
      %Answer{value: :timeout}
    else
      normalize_answer(answer)
    end
  end

  defp normalize_answer(%Answer{} = answer), do: answer
  defp normalize_answer(nil), do: %Answer{value: :skipped}
  defp normalize_answer(answer) when is_binary(answer), do: %Answer{value: answer}
  defp normalize_answer(answer) when is_atom(answer), do: %Answer{value: answer}
  defp normalize_answer(%{value: value}), do: %Answer{value: value}
  defp normalize_answer(_), do: %Answer{value: :skipped}
end
