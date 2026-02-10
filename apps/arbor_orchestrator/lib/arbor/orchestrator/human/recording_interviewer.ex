defmodule Arbor.Orchestrator.Human.RecordingInterviewer do
  @moduledoc false

  @behaviour Arbor.Orchestrator.Human.Interviewer

  alias Arbor.Orchestrator.Human.{Answer, AutoApproveInterviewer, Question, QueueInterviewer}

  @impl true
  def ask(%Question{} = question, opts \\ []) do
    inner = Keyword.get(opts, :inner, {AutoApproveInterviewer, []})
    answer = call_inner(inner, question)

    case Keyword.get(opts, :recorder) do
      callback when is_function(callback, 2) -> callback.(question, answer)
      _ -> :ok
    end

    answer
  end

  defp call_inner(fun, question) when is_function(fun, 1), do: normalize(fun.(question))

  defp call_inner({module, module_opts}, question)
       when is_atom(module) and is_list(module_opts) do
    Code.ensure_loaded(module)
    normalize(apply(module, :ask, [question, module_opts]))
  rescue
    _ -> normalize(AutoApproveInterviewer.ask(question, []))
  end

  defp call_inner(module, question) when is_atom(module) do
    Code.ensure_loaded(module)
    normalize(apply(module, :ask, [question, []]))
  rescue
    _ -> normalize(AutoApproveInterviewer.ask(question, []))
  end

  defp call_inner(_, question), do: normalize(QueueInterviewer.ask(question, []))

  defp normalize(%Answer{} = answer), do: answer
  defp normalize(%{value: value}), do: %Answer{value: value}
  defp normalize(value) when is_binary(value), do: %Answer{value: value}
  defp normalize(value) when is_atom(value), do: %Answer{value: value}
  defp normalize(_), do: %Answer{value: :skipped}
end
