defmodule Arbor.Actions.Judge.PromptBuilder do
  @moduledoc """
  Builds LLM prompts for the judge and parses JSON responses into Verdicts.
  """

  alias Arbor.Common.SafeAtom
  alias Arbor.Contracts.Judge.{Rubric, Verdict}

  @doc """
  Build system and user prompts for the LLM judge.

  ## Parameters

  - `subject` — map with `:content` (the text being judged)
  - `rubric` — the `Rubric` to evaluate against
  - `evidence_summary` — map from `EvidenceRunner.summarize/1`
  - `mode` — `:critique` or `:verification`
  - `opts` — optional overrides (`:intent`, `:peers`)

  Returns `{system_prompt, user_prompt}`.
  """
  @spec build(map(), Rubric.t(), map(), atom(), keyword()) :: {String.t(), String.t()}
  def build(subject, rubric, evidence_summary, mode, opts \\ []) do
    system = build_system_prompt(rubric, evidence_summary, mode)
    user = build_user_prompt(subject, opts)
    {system, user}
  end

  @doc """
  Parse a JSON response string into a Verdict struct.

  Extracts dimension scores, strengths, weaknesses, and recommendation
  from the judge's JSON response.
  """
  @spec parse_response(String.t(), Rubric.t(), atom()) :: {:ok, Verdict.t()} | {:error, term()}
  def parse_response(response, rubric, mode) do
    # Try to extract JSON from the response (may be wrapped in markdown)
    json_str = extract_json(response)

    case Jason.decode(json_str) do
      {:ok, parsed} ->
        build_verdict(parsed, rubric, mode)

      {:error, _} ->
        {:error, {:invalid_json, "Judge response is not valid JSON"}}
    end
  end

  # ============================================================================
  # System Prompt
  # ============================================================================

  defp build_system_prompt(rubric, evidence_summary, mode) do
    dimensions_text =
      rubric.dimensions
      |> Enum.map(fn dim ->
        "- #{dim[:name]} (weight: #{dim[:weight]}): #{dim[:description]}"
      end)
      |> Enum.join("\n")

    evidence_text =
      case evidence_summary["checks"] do
        checks when is_list(checks) and length(checks) > 0 ->
          checks
          |> Enum.map(fn c ->
            status = if c["passed"], do: "PASS", else: "FAIL"
            "- [#{status}] #{c["type"]}: #{c["detail"]} (score: #{c["score"]})"
          end)
          |> Enum.join("\n")

        _ ->
          "No pre-computed evidence available."
      end

    """
    You are an expert evaluator judging the quality of AI-generated output.
    Mode: #{mode}

    ## Rubric: #{rubric.domain} (v#{rubric.version})

    Score each dimension from 0.0 to 1.0:
    #{dimensions_text}

    ## Pre-Computed Evidence

    #{evidence_text}

    Aggregate evidence score: #{evidence_summary["aggregate_score"]}

    ## Response Format

    Respond with a JSON object (no markdown fences, just raw JSON):
    {
      "overall_score": 0.0-1.0,
      "dimension_scores": {"dimension_name": 0.0-1.0, ...},
      "strengths": ["strength 1", ...],
      "weaknesses": ["weakness 1", ...],
      "recommendation": "keep" | "revise" | "reject",
      "confidence": 0.0-1.0
    }

    Score guidelines:
    - 0.0-0.3: Poor quality, major issues
    - 0.3-0.6: Acceptable but notable weaknesses
    - 0.6-0.8: Good quality with minor issues
    - 0.8-1.0: Excellent quality

    Recommendation guidelines:
    - "keep": overall_score >= 0.6 and no critical weaknesses
    - "revise": overall_score 0.3-0.6 or has fixable issues
    - "reject": overall_score < 0.3 or fundamental problems
    """
  end

  # ============================================================================
  # User Prompt
  # ============================================================================

  defp build_user_prompt(subject, opts) do
    content = Map.get(subject, :content, "")
    intent = Keyword.get(opts, :intent)
    peers = Keyword.get(opts, :peers)

    parts = ["## Output to Evaluate\n\n#{content}"]

    parts =
      if intent do
        parts ++ ["\n## Intent/Task\n\n#{intent}"]
      else
        parts
      end

    parts =
      if peers && is_list(peers) && length(peers) > 0 do
        peer_text = Enum.map_join(peers, "\n---\n", & &1)
        parts ++ ["\n## Peer Outputs (for comparison)\n\n#{peer_text}"]
      else
        parts
      end

    Enum.join(parts, "\n")
  end

  # ============================================================================
  # Response Parsing
  # ============================================================================

  defp extract_json(text) do
    # Try to extract JSON from markdown code fences first
    case Regex.run(~r/```(?:json)?\s*\n?([\s\S]*?)\n?```/, text) do
      [_, json] -> String.trim(json)
      nil -> String.trim(text)
    end
  end

  defp build_verdict(parsed, rubric, mode) do
    overall = parse_float(parsed["overall_score"], 0.5)

    dimension_scores =
      case parsed["dimension_scores"] do
        scores when is_map(scores) ->
          Map.new(scores, fn {k, v} ->
            {safe_to_atom(k), parse_float(v, 0.5)}
          end)

        _ ->
          compute_dimension_scores(overall, rubric)
      end

    recommendation =
      case parsed["recommendation"] do
        "keep" -> :keep
        "revise" -> :revise
        "reject" -> :reject
        _ -> infer_recommendation(overall)
      end

    confidence = parse_float(parsed["confidence"], 0.5)

    Verdict.new(%{
      overall_score: overall,
      dimension_scores: dimension_scores,
      strengths: parse_list(parsed["strengths"]),
      weaknesses: parse_list(parsed["weaknesses"]),
      recommendation: recommendation,
      mode: mode,
      meta: %{
        judge_confidence: confidence
      }
    })
  end

  defp parse_float(val, _default) when is_number(val) do
    val |> max(0.0) |> min(1.0) |> Float.round(3)
  end

  defp parse_float(val, default) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> parse_float(f, default)
      :error -> default
    end
  end

  defp parse_float(_, default), do: default

  defp parse_list(list) when is_list(list) do
    Enum.filter(list, &is_binary/1)
  end

  defp parse_list(_), do: []

  defp safe_to_atom(str) when is_binary(str) do
    case SafeAtom.to_existing(str) do
      {:ok, atom} -> atom
      {:error, _} -> str
    end
  end

  defp compute_dimension_scores(overall, rubric) do
    Map.new(rubric.dimensions, fn dim ->
      {dim[:name], overall}
    end)
  end

  defp infer_recommendation(score) when score >= 0.6, do: :keep
  defp infer_recommendation(score) when score >= 0.3, do: :revise
  defp infer_recommendation(_), do: :reject
end
