defmodule Arbor.Persistence.VerdictLog do
  @moduledoc """
  Shared persistence projection for the LLM-opinion systems: writes a
  `Arbor.Contracts.Judge.Verdict` to the eval tables (`EvalRun` + `EvalResult`)
  so every opinion — judge critique, security verify-finding, and council (via
  `CouncilDecision.to_verdict/1`) — is observable in one place (the eval
  dashboard), partitioned by `domain`.

  This is the consolidation seam (see the consolidate-llm-opinion-systems
  roadmap item). It lives in `arbor_persistence` (Level 1) — which owns the
  eval tables — precisely so that **every** opinion producer can reach it,
  including `arbor_consensus` (Level 1). It originally lived in `arbor_actions`
  (Level 2), which blocked council from using it and left
  `CouncilDecision.to_verdict/1` defined-but-dead; the 2026-06-10 architecture
  review flagged that misplacement as the keystone, and this relocation closes it.

  Writes go through the `Arbor.Persistence` facade's eval inserts and degrade
  silently when the Repo isn't running — observability must never break the
  opinion flow.

  ## Options

  - `:domain`           — required; the eval-table partition (e.g. "llm_judge",
                          "security_verify", "council_decision", "code_review")
  - `:model`/`:provider`— the deciding model (default "unknown")
  - `:dataset`          — run dataset label (default: the domain)
  - `:graders`          — run graders list (default: `[domain]`)
  - `:source`           — provenance tag stored in run + result metadata
  - `:sample_id`        — result sample id (default "verdict")
  - `:input`            — the subject text (truncated to 10KB)
  - `:duration_ms`      — result duration
  - `:config`           — extra run config map (merged)
  - `:run_metadata`     — extra run metadata map (merged)
  - `:result_metadata`  — extra result metadata map (merged)
  """

  alias Arbor.Contracts.Judge.Verdict

  require Logger

  @max_input_bytes 10_000

  @doc """
  Record a verdict as an `EvalRun` + `EvalResult`. Returns `{:ok, run_id}` on
  success, or `:ok` when persistence is unavailable or the write fails (silent
  degradation — observability must never break the opinion flow).
  """
  @spec record(Verdict.t(), keyword()) :: {:ok, String.t()} | :ok
  def record(%Verdict{} = verdict, opts) do
    domain = Keyword.fetch!(opts, :domain)

    if repo_started?() do
      {run_attrs, result_attrs} = project(verdict, opts)

      with {:ok, _} <- Arbor.Persistence.insert_eval_run(run_attrs),
           {:ok, _} <- Arbor.Persistence.insert_eval_result(result_attrs) do
        Logger.debug("VerdictLog: stored #{domain} verdict #{run_attrs.id}")
        {:ok, run_attrs.id}
      else
        {:error, reason} ->
          Logger.debug("VerdictLog: #{domain} write failed: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  @doc """
  Pure projection of a verdict + opts into `{run_attrs, result_attrs}` — the two
  eval-table records, sharing a freshly-generated `run_id`. Exposed so the
  projection can be tested without a database (the write path in `record/2`
  degrades silently when the Repo is down).
  """
  @spec project(Verdict.t(), keyword()) :: {map(), map()}
  def project(%Verdict{} = verdict, opts) do
    domain = Keyword.fetch!(opts, :domain)
    run_id = generate_id()

    run_attrs = %{
      id: run_id,
      domain: domain,
      model: Keyword.get(opts, :model, "unknown"),
      provider: Keyword.get(opts, :provider, "unknown"),
      dataset: Keyword.get(opts, :dataset, domain),
      sample_count: 1,
      status: "completed",
      graders: Keyword.get(opts, :graders, [domain]),
      config: Keyword.get(opts, :config, %{}),
      metadata:
        Map.merge(
          %{"source" => Keyword.get(opts, :source, domain), "mode" => to_string(verdict.mode)},
          Keyword.get(opts, :run_metadata, %{})
        )
    }

    {run_attrs, build_result(run_id, verdict, opts)}
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp build_result(run_id, %Verdict{} = verdict, opts) do
    dimension_scores = Map.new(verdict.dimension_scores, fn {k, v} -> {to_string(k), v} end)
    scores = Map.put(dimension_scores, "overall", verdict.overall_score)

    %{
      id: generate_id(),
      run_id: run_id,
      sample_id: Keyword.get(opts, :sample_id, "verdict"),
      input: truncate(Keyword.get(opts, :input, "")),
      actual: Jason.encode!(verdict_to_map(verdict)),
      passed: Verdict.passed?(verdict),
      scores: scores,
      duration_ms: Keyword.get(opts, :duration_ms, 0),
      metadata:
        Map.merge(
          %{
            "source" => Keyword.get(opts, :source, "opinion"),
            "mode" => to_string(verdict.mode),
            "recommendation" => to_string(verdict.recommendation),
            "strengths" => verdict.strengths,
            "weaknesses" => verdict.weaknesses
          },
          Keyword.get(opts, :result_metadata, %{})
        )
    }
  end

  # Verdict → JSON-safe map. Includes meta so domain-specific detail (e.g.
  # security's decision/refuted/dissent, council's vote counts) is preserved.
  defp verdict_to_map(%Verdict{} = v) do
    %{
      overall_score: v.overall_score,
      dimension_scores: Map.new(v.dimension_scores, fn {k, val} -> {to_string(k), val} end),
      strengths: v.strengths,
      weaknesses: v.weaknesses,
      recommendation: to_string(v.recommendation),
      mode: to_string(v.mode),
      meta: jsonable(v.meta)
    }
  end

  # meta can carry atoms (e.g. decision: :refuted) — stringify atom values so
  # Jason.encode! never chokes, while leaving primitives/lists/maps intact.
  defp jsonable(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, val} -> {to_string(k), jsonable(val)} end)
  end

  defp jsonable(val) when is_atom(val) and val not in [nil, true, false], do: to_string(val)
  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(other), do: other

  defp truncate(content) when is_binary(content) do
    if byte_size(content) > @max_input_bytes,
      do: String.slice(content, 0, @max_input_bytes),
      else: content
  end

  defp truncate(_), do: ""

  defp repo_started? do
    is_pid(GenServer.whereis(Arbor.Persistence.Repo))
  rescue
    _ -> false
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.hex_encode32(case: :lower, padding: false)
  end
end
