defmodule Arbor.Actions.Judge.ResultStore do
  @moduledoc """
  Persists judge verdicts as EvalRun + EvalResult records.

  Thin adapter over the shared `Arbor.Persistence.VerdictLog`: it supplies
  the judge-specific edges (domain `"llm_judge"`, perspective dataset, rubric
  config + snapshot) and lets the shared projection do the Verdict→eval-tables
  write. See the consolidate-llm-opinion-systems roadmap item.
  """

  alias Arbor.Contracts.Judge.Rubric
  alias Arbor.Persistence.VerdictLog

  @domain "llm_judge"

  @doc """
  Store a verdict as an EvalResult under an EvalRun.

  Returns the run ID on success, `:ok` on degradation/failure.

  ## Parameters

  - `verdict` — the `Verdict` struct
  - `subject` — map with `:content`, `:perspective`, etc.
  - `rubric` — the `Rubric` used
  - `opts` — additional metadata (`:judge_model`, `:evidence_count`, etc.)
  """
  @spec store(map(), map(), map(), keyword()) :: {:ok, String.t()} | :ok
  def store(verdict, subject, rubric, opts \\ []) do
    sample_id =
      case Map.get(verdict, :mode) do
        :verification -> "judge_verify"
        _ -> "judge_verdict"
      end

    VerdictLog.record(verdict,
      domain: @domain,
      model: Keyword.get(opts, :judge_model, "unknown"),
      provider: Keyword.get(opts, :judge_provider, "unknown"),
      dataset: slugify(Map.get(subject, :perspective, "judge")),
      graders: ["llm_judge"],
      source: "judge_evaluate",
      sample_id: sample_id,
      input: Map.get(subject, :content, ""),
      duration_ms: Keyword.get(opts, :duration_ms, 0),
      config: %{
        "rubric_domain" => Map.get(rubric, :domain, "unknown"),
        "rubric_version" => Map.get(rubric, :version, 1),
        "mode" => to_string(Map.get(verdict, :mode, :critique))
      },
      run_metadata: %{"evidence_count" => Keyword.get(opts, :evidence_count, 0)},
      result_metadata: %{
        "grader" => "llm_judge",
        "rubric_snapshot" => rubric_snapshot(rubric),
        "judge_model" => Keyword.get(opts, :judge_model, "unknown"),
        "judge_provider" => Keyword.get(opts, :judge_provider, "unknown"),
        "evidence_count" => Keyword.get(opts, :evidence_count, 0)
      }
    )
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp rubric_snapshot(rubric) when is_struct(rubric), do: Rubric.snapshot(rubric)
  defp rubric_snapshot(_), do: %{}

  defp slugify(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.split()
    |> Enum.take(8)
    |> Enum.join("-")
  end

  defp slugify(text) when is_atom(text), do: slugify(to_string(text))
  defp slugify(_), do: "unknown"
end
