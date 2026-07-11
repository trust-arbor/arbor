defmodule Arbor.Orchestrator.Eval do
  @moduledoc """
  Evaluation framework for systematic testing of LLMs, code generators,
  or any callable system using DOT-defined eval pipelines with JSONL datasets.

  ## Graders

  Graders compare actual vs expected output:

    - `exact_match` — string equality
    - `contains` — substring check
    - `regex` — regex pattern match
    - `json_valid` — valid JSON check
    - `dot_diff` — structural DOT comparison
    - `composite` — weighted combination of graders

  ## Metrics

    - `accuracy` — fraction of samples passing all graders
    - `mean_score` — average score across samples
    - `pass_at_k` — unbiased estimator for pass rate in k attempts
  """

  alias Arbor.Orchestrator.Eval.Graders

  @graders %{
    "exact_match" => Graders.ExactMatch,
    "contains" => Graders.Contains,
    "regex" => Graders.RegexMatch,
    "json_valid" => Graders.JsonValid,
    "dot_diff" => Graders.DotDiff,
    "composite" => Graders.Composite,
    "compile_check" => Graders.CompileCheck,
    "functional_test" => Graders.FunctionalTest,
    "code_quality" => Graders.CodeQuality,
    "embedding_similarity" => Graders.EmbeddingSimilarity,
    "intent_conformance" => Graders.IntentConformance,
    "precision_at_1" => Graders.PrecisionAt1,
    "precision_at_5" => Graders.PrecisionAt5,
    "recall_at_5" => Graders.RecallAt5
  }

  @doc "Returns the grader module for a given name."
  @spec grader(String.t()) :: module() | nil
  def grader(name), do: Map.get(@graders, name)

  @doc "Returns all registered grader names."
  @spec grader_names() :: [String.t()]
  def grader_names, do: Map.keys(@graders)

  @doc """
  Loads a JSONL file into a list of sample maps.

  Each line is a JSON object with at minimum `input` and `expected` keys.
  """
  @spec load_dataset(String.t(), keyword()) :: {:ok, [map()]} | {:error, String.t()}
  defdelegate load_dataset(path, opts \\ []), to: Arbor.Eval.Pipeline

  @doc """
  Runs evaluation: applies subject to each sample, grades results.

  Returns a list of result maps.
  """
  @spec run_eval([map()], module(), [String.t()], keyword()) :: [map()]
  def run_eval(samples, subject_module, grader_names, opts \\ []) do
    graders = Enum.map(grader_names, &grader/1) |> Enum.reject(&is_nil/1)

    Arbor.Eval.Pipeline.run_eval(samples, subject_module, graders, opts)
  end
end
