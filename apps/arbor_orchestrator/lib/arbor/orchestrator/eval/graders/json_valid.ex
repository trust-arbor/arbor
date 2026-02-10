defmodule Arbor.Orchestrator.Eval.Graders.JsonValid do
  @moduledoc """
  Grader that checks if the actual output is valid JSON.
  """

  @behaviour Arbor.Orchestrator.Eval.Grader

  @impl true
  def grade(actual, _expected, _opts \\ []) do
    case Jason.decode(to_string(actual)) do
      {:ok, _} ->
        %{score: 1.0, passed: true, detail: "valid JSON"}

      {:error, reason} ->
        %{score: 0.0, passed: false, detail: "invalid JSON: #{inspect(reason)}"}
    end
  end
end
