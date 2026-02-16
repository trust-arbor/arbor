defmodule Arbor.Actions.Judge.ResultStore do
  @moduledoc """
  Persists judge verdicts as EvalRun + EvalResult records.

  Uses the same runtime bridge pattern as `ConsultationLog`:
  `Code.ensure_loaded?` + `apply/3` for graceful degradation
  when Postgres isn't running.
  """

  require Logger

  @persistence_mod Arbor.Persistence
  @domain "llm_judge"

  @doc """
  Store a verdict as an EvalResult under an EvalRun.

  Creates both the run and result records. Returns the run ID
  on success, nil on failure (silently degrades).

  ## Parameters

  - `verdict` — the `Verdict` struct
  - `subject` — map with `:content`, `:perspective`, etc.
  - `rubric` — the `Rubric` used
  - `opts` — additional metadata (`:judge_model`, `:evidence_count`, etc.)
  """
  @spec store(map(), map(), map(), keyword()) :: {:ok, String.t()} | :ok
  def store(verdict, subject, rubric, opts \\ []) do
    if available?() do
      run_id = generate_id()

      run_attrs = %{
        id: run_id,
        domain: @domain,
        model: Keyword.get(opts, :judge_model, "unknown"),
        provider: Keyword.get(opts, :judge_provider, "unknown"),
        dataset: slugify(Map.get(subject, :perspective, "judge")),
        sample_count: 1,
        status: "completed",
        graders: ["llm_judge"],
        config: %{
          "rubric_domain" => Map.get(rubric, :domain, "unknown"),
          "rubric_version" => Map.get(rubric, :version, 1),
          "mode" => to_string(Map.get(verdict, :mode, :critique))
        },
        metadata: %{
          "source" => "judge_evaluate",
          "evidence_count" => Keyword.get(opts, :evidence_count, 0)
        }
      }

      case apply(@persistence_mod, :insert_eval_run, [run_attrs]) do
        {:ok, _} ->
          result_attrs = build_result(run_id, verdict, subject, rubric, opts)

          case apply(@persistence_mod, :insert_eval_result, [result_attrs]) do
            {:ok, _} ->
              Logger.debug("ResultStore: stored verdict #{run_id}")
              {:ok, run_id}

            {:error, reason} ->
              Logger.debug("ResultStore: failed to store result: #{inspect(reason)}")
              :ok
          end

        {:error, reason} ->
          Logger.debug("ResultStore: failed to create run: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp available? do
    Code.ensure_loaded?(@persistence_mod) and
      function_exported?(@persistence_mod, :insert_eval_run, 1) and
      repo_started?()
  end

  defp repo_started? do
    repo = Arbor.Persistence.Repo
    Code.ensure_loaded?(repo) and is_pid(GenServer.whereis(repo))
  rescue
    _ -> false
  end

  defp build_result(run_id, verdict, subject, rubric, opts) do
    sample_id =
      case Map.get(verdict, :mode) do
        :verification -> "judge_verify"
        _ -> "judge_verdict"
      end

    content = Map.get(subject, :content, "")
    truncated = if byte_size(content) > 10_000, do: String.slice(content, 0, 10_000), else: content

    dimension_scores =
      Map.get(verdict, :dimension_scores, %{})
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    scores = Map.put(dimension_scores, "overall", Map.get(verdict, :overall_score, 0.0))

    rubric_snapshot =
      if is_struct(rubric) do
        Arbor.Contracts.Judge.Rubric.snapshot(rubric)
      else
        %{}
      end

    %{
      id: generate_id(),
      run_id: run_id,
      sample_id: sample_id,
      input: truncated,
      actual: Jason.encode!(verdict_to_map(verdict)),
      passed: Map.get(verdict, :recommendation) != :reject,
      scores: scores,
      duration_ms: Keyword.get(opts, :duration_ms, 0),
      metadata: %{
        "grader" => "llm_judge",
        "mode" => to_string(Map.get(verdict, :mode, :critique)),
        "rubric_snapshot" => rubric_snapshot,
        "judge_model" => Keyword.get(opts, :judge_model, "unknown"),
        "judge_provider" => Keyword.get(opts, :judge_provider, "unknown"),
        "evidence_count" => Keyword.get(opts, :evidence_count, 0),
        "recommendation" => to_string(Map.get(verdict, :recommendation)),
        "strengths" => Map.get(verdict, :strengths, []),
        "weaknesses" => Map.get(verdict, :weaknesses, [])
      }
    }
  end

  defp verdict_to_map(verdict) when is_struct(verdict) do
    %{
      overall_score: verdict.overall_score,
      dimension_scores: Map.new(verdict.dimension_scores, fn {k, v} -> {to_string(k), v} end),
      strengths: verdict.strengths,
      weaknesses: verdict.weaknesses,
      recommendation: to_string(verdict.recommendation),
      mode: to_string(verdict.mode)
    }
  end

  defp verdict_to_map(verdict) when is_map(verdict) do
    %{
      overall_score: Map.get(verdict, :overall_score, 0.0),
      recommendation: to_string(Map.get(verdict, :recommendation, :keep)),
      mode: to_string(Map.get(verdict, :mode, :critique))
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.hex_encode32(case: :lower, padding: false)
  end

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
