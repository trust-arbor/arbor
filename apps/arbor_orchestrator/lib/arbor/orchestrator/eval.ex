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
    "composite" => Graders.Composite
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
  def load_dataset(path, opts \\ []) do
    case File.read(path) do
      {:ok, content} ->
        samples =
          content
          |> String.split("\n", trim: true)
          |> Enum.with_index()
          |> Enum.flat_map(fn {line, idx} ->
            case Jason.decode(line) do
              {:ok, map} -> [Map.put_new(map, "id", "sample_#{idx}")]
              {:error, _} -> []
            end
          end)

        samples = maybe_shuffle(samples, opts)
        samples = maybe_limit(samples, opts)

        {:ok, samples}

      {:error, reason} ->
        {:error, "Failed to read dataset: #{inspect(reason)}"}
    end
  end

  @doc """
  Runs evaluation: applies subject to each sample, grades results.

  Returns a list of result maps.
  """
  @spec run_eval([map()], module(), [String.t()], keyword()) :: [map()]
  def run_eval(samples, subject_module, grader_names, opts \\ []) do
    graders = Enum.map(grader_names, &grader/1) |> Enum.reject(&is_nil/1)

    Enum.map(samples, fn sample ->
      input = sample["input"]
      expected = sample["expected"]

      actual =
        case subject_module.run(input, opts) do
          {:ok, result} -> result
          {:error, _} -> ""
        end

      scores =
        Enum.map(graders, fn grader_mod ->
          grader_mod.grade(actual, expected, opts)
        end)

      %{
        "id" => sample["id"],
        "input" => input,
        "expected" => expected,
        "actual" => actual,
        "scores" => scores,
        "passed" => Enum.all?(scores, & &1.passed),
        "metadata" => sample["metadata"]
      }
    end)
  end

  defp maybe_shuffle(samples, opts) do
    case Keyword.get(opts, :shuffle, false) do
      true ->
        seed = Keyword.get(opts, :seed, :rand.uniform(1_000_000))
        samples |> Enum.map(&{:rand.uniform_real(), &1}) |> Enum.sort() |> Enum.map(&elem(&1, 1))
        # Use deterministic shuffle with seed
        :rand.seed(:exsss, {seed, seed, seed})
        Enum.shuffle(samples)

      _ ->
        samples
    end
  end

  defp maybe_limit(samples, opts) do
    case Keyword.get(opts, :limit) do
      nil -> samples
      n when is_integer(n) -> Enum.take(samples, n)
      _ -> samples
    end
  end
end
