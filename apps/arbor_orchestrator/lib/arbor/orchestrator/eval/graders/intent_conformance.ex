defmodule Arbor.Orchestrator.Eval.Graders.IntentConformance do
  @moduledoc """
  LLM-as-judge grader that evaluates whether a generated DOT graph
  faithfully represents the intent of its source SKILL.md description.

  Unlike `dot_diff` which compares structural similarity to a reference DOT,
  this grader asks: "Does this DOT correctly implement what the skill describes?"

  Scores across 6 dimensions:
  - Phase coverage: Are all major phases/stages present?
  - Decision fidelity: Are decision points and conditions represented?
  - Loop correctness: Are iterations captured with safety guards?
  - Error handling: Are failure paths present where needed?
  - Handler type appropriateness: Are the right handler types used?
  - Prompt relevance: Do node prompts reference actual tasks?

  Requires an LLM call — uses the judge model (configurable, defaults to
  a fast model via OpenRouter).
  """

  @behaviour Arbor.Orchestrator.Eval.Grader

  require Logger

  @judge_prompt """
  You are an expert evaluator for DOT graph pipeline compilation quality.

  You will be given:
  1. A SKILL description (natural language workflow)
  2. A DOT graph that was compiled from that skill by an LLM

  Your job: evaluate how faithfully the DOT graph represents the skill's intent.

  Score each dimension from 0.0 to 1.0:

  1. **phase_coverage** — Are all major phases/stages/steps from the skill present as nodes?
     - 1.0 = all phases covered
     - 0.5 = most phases covered, some missing
     - 0.0 = major phases missing

  2. **decision_fidelity** — Are decision points, conditional paths, and branching represented?
     - 1.0 = all decisions correctly modeled with conditional edges
     - 0.5 = decisions present but edges/labels incomplete
     - 0.0 = decisions missing or wrong
     - N/A if skill has no decisions → score 1.0

  3. **loop_correctness** — Are iterations/loops captured with max_iterations safety?
     - 1.0 = loops present with max_iterations where needed
     - 0.5 = loops present but missing safety guards
     - 0.0 = loops missing when skill describes iteration
     - N/A if skill has no loops → score 1.0

  4. **error_handling** — Are failure/error paths present for risky operations?
     - 1.0 = error paths for shell/codergen nodes
     - 0.5 = some error handling, gaps remain
     - 0.0 = no error handling despite risky operations
     - N/A if no risky operations → score 1.0

  5. **handler_types** — Are appropriate handler types used for each task?
     - type="llm" for analysis, planning, review
     - type="codergen" for code generation
     - type="shell" for system commands (with simulate="true")
     - type="conditional" for decision nodes
     - type="start"/"exit" for entry/exit
     - 1.0 = all types appropriate
     - 0.5 = mostly correct, some mismatches
     - 0.0 = major type mismatches

  6. **prompt_relevance** — Do node prompts/labels reference actual tasks from the skill?
     - 1.0 = prompts clearly map to skill requirements
     - 0.5 = prompts are generic or partially relevant
     - 0.0 = prompts are unrelated to skill content

  Respond with ONLY a JSON object (no markdown, no explanation):
  {
    "phase_coverage": <float>,
    "decision_fidelity": <float>,
    "loop_correctness": <float>,
    "error_handling": <float>,
    "handler_types": <float>,
    "prompt_relevance": <float>,
    "overall": <float>,
    "brief_rationale": "<1-2 sentences>"
  }

  The "overall" score should be a weighted average reflecting your holistic assessment
  (not necessarily the arithmetic mean — weight more important dimensions higher).
  """

  @dimension_weights %{
    phase_coverage: 0.25,
    decision_fidelity: 0.15,
    loop_correctness: 0.10,
    error_handling: 0.10,
    handler_types: 0.20,
    prompt_relevance: 0.20
  }

  @impl true
  def grade(actual, _expected, opts \\ []) do
    actual_str = to_string(actual)

    # Get the original skill description from sample input
    sample_input = Keyword.get(opts, :sample_input, %{})

    skill_prompt =
      case sample_input do
        %{"prompt" => p} -> p
        p when is_binary(p) -> p
        _ -> ""
      end

    if actual_str == "" or skill_prompt == "" do
      %{
        score: 0.0,
        passed: false,
        detail: "Empty #{if actual_str == "", do: "DOT output", else: "skill input"}"
      }
    else
      judge_with_llm(skill_prompt, actual_str, opts)
    end
  end

  defp judge_with_llm(skill_text, dot_text, opts) do
    judge_model = Keyword.get(opts, :judge_model, "google/gemini-2.5-flash")
    judge_provider = Keyword.get(opts, :judge_provider, "openrouter")
    judge_timeout = Keyword.get(opts, :judge_timeout, 60_000)

    user_prompt = """
    ## SKILL DESCRIPTION

    #{skill_text}

    ## GENERATED DOT GRAPH

    #{dot_text}
    """

    case call_judge(judge_provider, judge_model, @judge_prompt, user_prompt, judge_timeout) do
      {:ok, response_text} ->
        parse_judge_response(response_text)

      {:error, reason} ->
        Logger.warning("[IntentConformance] Judge call failed: #{inspect(reason)}")
        %{score: 0.0, passed: false, detail: "Judge error: #{inspect(reason)}"}
    end
  end

  defp call_judge(provider, model, system_prompt, user_prompt, timeout) do
    alias Arbor.Orchestrator.UnifiedLLM.{Client, Request, Message}

    client = Client.default_client()

    request = %Request{
      provider: provider,
      model: model,
      messages: [
        Message.new(:system, system_prompt),
        Message.new(:user, user_prompt)
      ],
      max_tokens: 1024,
      temperature: 0.0
    }

    case Client.complete(client, request, timeout: timeout) do
      {:ok, %{text: text}} -> {:ok, text}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_judge_response(text) do
    # Extract JSON from response (may be wrapped in markdown fences)
    json_str =
      text
      |> String.replace(~r/<think>.*?<\/think>/s, "")
      |> extract_json()

    case Jason.decode(json_str) do
      {:ok, scores} when is_map(scores) ->
        dimensions = %{
          phase_coverage: get_score(scores, "phase_coverage"),
          decision_fidelity: get_score(scores, "decision_fidelity"),
          loop_correctness: get_score(scores, "loop_correctness"),
          error_handling: get_score(scores, "error_handling"),
          handler_types: get_score(scores, "handler_types"),
          prompt_relevance: get_score(scores, "prompt_relevance")
        }

        # Use judge's overall if provided, otherwise compute weighted average
        overall =
          case scores["overall"] do
            n when is_number(n) and n >= 0.0 and n <= 1.0 ->
              n

            _ ->
              Enum.reduce(dimensions, 0.0, fn {dim, score}, acc ->
                acc + score * Map.get(@dimension_weights, dim, 0.0)
              end)
          end

        overall = Float.round(overall, 2)
        rationale = scores["brief_rationale"] || ""

        detail =
          "phase=#{fmt(dimensions.phase_coverage)} decision=#{fmt(dimensions.decision_fidelity)} " <>
            "loop=#{fmt(dimensions.loop_correctness)} error=#{fmt(dimensions.error_handling)} " <>
            "handler=#{fmt(dimensions.handler_types)} prompt=#{fmt(dimensions.prompt_relevance)}" <>
            if(rationale != "", do: " | #{rationale}", else: "")

        %{
          score: overall,
          passed: overall >= 0.6,
          detail: detail
        }

      {:error, _} ->
        Logger.warning(
          "[IntentConformance] Failed to parse judge JSON: #{String.slice(text, 0..200)}"
        )

        %{score: 0.0, passed: false, detail: "JSON parse error: #{String.slice(text, 0..100)}"}
    end
  end

  defp extract_json(text) do
    # Try to find JSON in markdown fences first
    case Regex.run(~r/```(?:json)?\s*\n?(.*?)\n?```/s, text) do
      [_, json] ->
        String.trim(json)

      nil ->
        # Try to find bare JSON object
        case Regex.run(~r/(\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\})/s, text) do
          [_, json] -> json
          nil -> text
        end
    end
  end

  defp get_score(scores, key) do
    case scores[key] do
      n when is_number(n) -> min(max(n, 0.0), 1.0)
      _ -> 0.5
    end
  end

  defp fmt(val), do: Float.round(val * 1.0, 2) |> to_string()
end
