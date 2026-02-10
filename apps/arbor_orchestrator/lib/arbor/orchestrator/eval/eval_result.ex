defmodule Arbor.Orchestrator.Eval.EvalResult do
  @moduledoc "Result of evaluating a single sample: actual output, scores, and timing."

  @type t :: %__MODULE__{
          sample_id: String.t(),
          input: any(),
          expected: any(),
          actual: any(),
          scores: %{String.t() => float()},
          passed: boolean(),
          grader_details: [map()],
          duration_ms: non_neg_integer(),
          metadata: map()
        }

  @derive Jason.Encoder
  defstruct sample_id: "",
            input: nil,
            expected: nil,
            actual: nil,
            scores: %{},
            passed: false,
            grader_details: [],
            duration_ms: 0,
            metadata: %{}

  @doc "Compute the average score across all graders."
  def avg_score(%__MODULE__{scores: scores}) when map_size(scores) == 0, do: 0.0

  def avg_score(%__MODULE__{scores: scores}) do
    scores
    |> Map.values()
    |> Enum.sum()
    |> Kernel./(map_size(scores))
  end

  @doc "Convert to a JSON-serializable map."
  def to_map(%__MODULE__{} = r) do
    %{
      "sample_id" => r.sample_id,
      "input" => r.input,
      "expected" => r.expected,
      "actual" => r.actual,
      "scores" => r.scores,
      "passed" => r.passed,
      "grader_details" => r.grader_details,
      "duration_ms" => r.duration_ms,
      "metadata" => r.metadata
    }
  end
end
