defmodule Arbor.Orchestrator.Human.CallbackInterviewer do
  @moduledoc false

  @behaviour Arbor.Orchestrator.Human.Interviewer

  alias Arbor.Orchestrator.Human.{Answer, Question}

  @impl true
  def ask(%Question{} = question, opts \\ []) do
    callback = Keyword.get(opts, :callback)
    normalize(call(callback, question, opts))
  end

  defp call(fun, question, _opts) when is_function(fun, 1), do: fun.(question)
  defp call(fun, question, opts) when is_function(fun, 2), do: fun.(question, opts)
  defp call(_, _question, _opts), do: :skipped

  defp normalize(%Answer{} = answer), do: answer
  defp normalize(%{value: value} = map), do: %Answer{value: value, text: map[:text]}
  defp normalize(value) when is_binary(value), do: %Answer{value: value}
  defp normalize(value) when is_atom(value), do: %Answer{value: value}
  defp normalize(_), do: %Answer{value: :skipped}
end
