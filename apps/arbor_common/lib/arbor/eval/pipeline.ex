defmodule Arbor.Eval.Pipeline do
  @moduledoc """
  Generic JSONL evaluation pipeline runtime.

  The public `Arbor.Eval` facade resolves symbolic subject and grader names
  through a closed catalog. This module also accepts explicit modules for
  compatibility callers that already own and trust those module identities.
  """

  @doc """
  Loads JSONL samples from `path`.

  Invalid JSON lines are skipped. Samples without an `"id"` receive a stable
  `"sample_N"` id based on their zero-based nonblank line position.
  """
  @spec load_dataset(String.t(), keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def load_dataset(path, opts \\ []) do
    case File.read(path) do
      {:ok, content} ->
        samples =
          content
          |> String.split("\n", trim: true)
          |> Enum.with_index()
          |> Enum.flat_map(fn {line, index} ->
            case Jason.decode(line) do
              {:ok, sample} -> [Map.put_new(sample, "id", "sample_#{index}")]
              {:error, _reason} -> []
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
  Runs trusted subject and grader modules over a list of samples.

  Module selection is deliberately outside this function. Untrusted callers
  should use the closed string catalogs exposed by `Arbor.Eval`.
  """
  @spec run_eval([map()], module(), [module()], keyword()) :: [map()]
  def run_eval(samples, subject_module, grader_modules, opts \\ []) do
    Enum.map(samples, fn sample ->
      input = sample["input"]
      expected = sample["expected"]
      actual = run_subject(subject_module, input, opts)

      scores =
        Enum.map(grader_modules, fn grader_module ->
          grader_module.grade(actual, expected, opts)
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

  defp run_subject(subject_module, input, opts) do
    case subject_module.run(input, opts) do
      {:ok, %{text: text}} -> text
      {:ok, result} when is_binary(result) -> result
      {:ok, result} -> to_string(result)
      {:error, _reason} -> ""
    end
  end

  defp maybe_shuffle(samples, opts) do
    case Keyword.get(opts, :shuffle, false) do
      true ->
        seed = Keyword.get(opts, :seed, :rand.uniform(1_000_000))
        :rand.seed(:exsss, {seed, seed, seed})
        Enum.shuffle(samples)

      _other ->
        samples
    end
  end

  defp maybe_limit(samples, opts) do
    case Keyword.get(opts, :limit) do
      nil -> samples
      limit when is_integer(limit) -> Enum.take(samples, limit)
      _other -> samples
    end
  end
end
