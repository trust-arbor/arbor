defmodule Arbor.AI.Eval.Graders.IntentConformance do
  @moduledoc """
  LLM-as-judge grader for conformance between a workflow description and DOT.

  The source description is read from `opts[:sample_input]`. The `:judge_fn`
  option accepts an injectable
  `(provider, model, system_prompt, user_prompt, timeout -> result)` callback.
  `:max_tokens` remains unset by default. Explicit positive signed 64-bit
  protocol integers are forwarded without a guessed model-policy ceiling.
  """

  @behaviour Arbor.Eval.Grader

  require Logger

  alias Arbor.AI.Eval.RetrievalSupport

  @judge_prompt """
  You are an expert evaluator for DOT graph pipeline compilation quality.

  You will be given:
  1. A SKILL description (natural language workflow)
  2. A DOT graph that was compiled from that skill by an LLM

  Your job: evaluate how faithfully the DOT graph represents the skill's intent.

  Score each dimension from 0.0 to 1.0:

  1. **phase_coverage** - Are all major phases/stages/steps from the skill present as nodes?
     - 1.0 = all phases covered
     - 0.5 = most phases covered, some missing
     - 0.0 = major phases missing

  2. **decision_fidelity** - Are decision points, conditional paths, and branching represented?
     - 1.0 = all decisions correctly modeled with conditional edges
     - 0.5 = decisions present but edges/labels incomplete
     - 0.0 = decisions missing or wrong
     - N/A if skill has no decisions: score 1.0

  3. **loop_correctness** - Are iterations/loops captured with max_iterations safety?
     - 1.0 = loops present with max_iterations where needed
     - 0.5 = loops present but missing safety guards
     - 0.0 = loops missing when skill describes iteration
     - N/A if skill has no loops: score 1.0

  4. **error_handling** - Are failure/error paths present for risky operations?
     - 1.0 = error paths for shell/codergen nodes
     - 0.5 = some error handling, gaps remain
     - 0.0 = no error handling despite risky operations
     - N/A if no risky operations: score 1.0

  5. **handler_types** - Are appropriate handler types used for each task?
     - type="llm" for analysis, planning, review
     - type="codergen" for code generation
     - type="shell" for system commands (with simulate="true")
     - type="conditional" for decision nodes
     - type="start"/"exit" for entry/exit
     - 1.0 = all types appropriate
     - 0.5 = mostly correct, some mismatches
     - 0.0 = major type mismatches

  6. **prompt_relevance** - Do node prompts/labels reference actual tasks from the skill?
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
  (not necessarily the arithmetic mean - weight more important dimensions higher).
  """

  @dimension_weights %{
    phase_coverage: 0.25,
    decision_fidelity: 0.15,
    loop_correctness: 0.10,
    error_handling: 0.10,
    handler_types: 0.20,
    prompt_relevance: 0.20
  }

  @default_model "google/gemini-2.5-flash"
  @default_provider "openrouter"
  @default_timeout 60_000
  @max_judge_response_bytes 32_768
  @max_rationale_bytes 512
  @max_detail_bytes 1_024
  @max_skill_input_bytes 1_048_576
  @max_dot_input_bytes 1_048_576
  @max_user_prompt_bytes 1_572_864

  @impl true
  def grade(actual, _expected, opts \\ []) do
    with :ok <- RetrievalSupport.validate_opts(opts),
         {:ok, actual_text} <- normalize_actual(actual),
         {:ok, skill_text} <- extract_skill_input(Keyword.get(opts, :sample_input, %{})),
         {:ok, judge_model} <-
           RetrievalSupport.string_option(opts, :judge_model, @default_model),
         {:ok, judge_provider} <-
           RetrievalSupport.string_option(opts, :judge_provider, @default_provider),
         {:ok, judge_timeout} <-
           RetrievalSupport.positive_integer_option(opts, :judge_timeout, @default_timeout),
         {:ok, max_tokens} <-
           RetrievalSupport.optional_positive_integer_option(opts, :max_tokens),
         {:ok, judge_fn} <-
           RetrievalSupport.callback_option(
             opts,
             :judge_fn,
             5,
             fn provider, model, system_prompt, user_prompt, timeout ->
               default_judge(
                 provider,
                 model,
                 system_prompt,
                 user_prompt,
                 timeout,
                 max_tokens
               )
             end
           ) do
      judge(skill_text, actual_text, judge_provider, judge_model, judge_timeout, judge_fn)
    else
      {:error, :empty_dot_output} -> failure("Empty DOT output")
      {:error, :empty_skill_input} -> failure("Empty skill input")
      {:error, reason} -> failure("Invalid grader input: #{inspect_bounded(reason)}")
    end
  end

  defp normalize_actual(actual) when is_binary(actual) and actual != "" do
    validate_input_text(actual, :dot, @max_dot_input_bytes)
  end

  defp normalize_actual(""), do: {:error, :empty_dot_output}
  defp normalize_actual(_actual), do: {:error, {:invalid_input, :dot_text_required}}

  defp extract_skill_input(%{"prompt" => prompt}) when is_binary(prompt) and prompt != "" do
    validate_input_text(prompt, :skill, @max_skill_input_bytes)
  end

  defp extract_skill_input(prompt) when is_binary(prompt) and prompt != "" do
    validate_input_text(prompt, :skill, @max_skill_input_bytes)
  end

  defp extract_skill_input(""), do: {:error, :empty_skill_input}
  defp extract_skill_input(_input), do: {:error, :empty_skill_input}

  defp judge(skill_text, dot_text, provider, model, timeout, judge_fn) do
    user_prompt = """
    ## SKILL DESCRIPTION

    #{skill_text}

    ## GENERATED DOT GRAPH

    #{dot_text}
    """

    with :ok <- validate_total_prompt(user_prompt),
         response <-
           RetrievalSupport.invoke(
             judge_fn,
             [provider, model, @judge_prompt, user_prompt, timeout],
             :judge_callback_failed
           ) do
      handle_judge_response(response)
    else
      {:error, reason} -> failure("Invalid grader input: #{inspect_bounded(reason)}")
    end
  end

  defp handle_judge_response(response) do
    case response do
      {:ok, response_text} when is_binary(response_text) ->
        response_text
        |> clean_text(@max_judge_response_bytes)
        |> parse_judge_response()

      {:ok, _response} ->
        failure("Judge error: invalid response")

      {:error, reason} ->
        reason = inspect_bounded(reason)
        Logger.warning("[IntentConformance] Judge call failed: #{reason}")
        failure("Judge error: #{reason}")

      _response ->
        failure("Judge error: invalid response")
    end
  end

  defp validate_input_text(text, field, maximum) do
    cond do
      byte_size(text) > maximum -> {:error, {field, :byte_size_exceeded, maximum}}
      String.valid?(text) -> {:ok, text}
      true -> {:error, {field, :valid_utf8_required}}
    end
  end

  defp validate_total_prompt(user_prompt) do
    if byte_size(user_prompt) <= @max_user_prompt_bytes,
      do: :ok,
      else: {:error, {:judge_prompt_bytes_exceeded, @max_user_prompt_bytes}}
  end

  defp default_judge(provider, model, system_prompt, user_prompt, timeout, max_tokens) do
    generate_opts =
      [
        provider: provider,
        model: model,
        system: system_prompt,
        prompt: user_prompt,
        temperature: 0.0,
        timeout_ms: timeout
      ]
      |> maybe_put(:max_tokens, max_tokens)

    case Arbor.LLM.generate(generate_opts) do
      {:ok, %{text: text}} when is_binary(text) -> {:ok, text}
      {:ok, _response} -> {:error, :missing_response_text}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_judge_response(text) do
    json =
      text
      |> String.replace(~r/<think>.*?<\/think>/s, "")
      |> extract_json()

    case Jason.decode(json) do
      {:ok, scores} when is_map(scores) -> build_result(scores)
      _error -> parse_failure(text)
    end
  end

  defp build_result(scores) do
    dimensions = %{
      phase_coverage: get_score(scores, "phase_coverage"),
      decision_fidelity: get_score(scores, "decision_fidelity"),
      loop_correctness: get_score(scores, "loop_correctness"),
      error_handling: get_score(scores, "error_handling"),
      handler_types: get_score(scores, "handler_types"),
      prompt_relevance: get_score(scores, "prompt_relevance")
    }

    overall =
      case unit_score(scores["overall"]) do
        {:ok, value} -> value
        :error -> weighted_score(dimensions)
      end
      |> Float.round(2)

    rationale =
      case scores["brief_rationale"] do
        value when is_binary(value) -> clean_text(value, @max_rationale_bytes)
        _value -> ""
      end

    detail =
      "phase=#{format_score(dimensions.phase_coverage)} " <>
        "decision=#{format_score(dimensions.decision_fidelity)} " <>
        "loop=#{format_score(dimensions.loop_correctness)} " <>
        "error=#{format_score(dimensions.error_handling)} " <>
        "handler=#{format_score(dimensions.handler_types)} " <>
        "prompt=#{format_score(dimensions.prompt_relevance)}" <>
        if(rationale == "", do: "", else: " | #{rationale}")

    %{score: overall, passed: overall >= 0.6, detail: clean_text(detail, @max_detail_bytes)}
  end

  defp weighted_score(dimensions) do
    Enum.reduce(dimensions, 0.0, fn {dimension, score}, total ->
      total + score * Map.fetch!(@dimension_weights, dimension)
    end)
  end

  defp extract_json(text) do
    case Regex.run(~r/```(?:json)?\s*\n?(.*?)\n?```/s, text) do
      [_, json] ->
        String.trim(json)

      nil ->
        case Regex.run(~r/(\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\})/s, text) do
          [_, json] -> json
          nil -> text
        end
    end
  end

  defp get_score(scores, key) do
    case scores[key] do
      value when is_integer(value) and value <= 0 -> 0.0
      value when is_integer(value) and value >= 1 -> 1.0
      value when is_float(value) and value <= 0.0 -> 0.0
      value when is_float(value) and value >= 1.0 -> 1.0
      value when is_float(value) -> value
      _value -> 0.5
    end
  end

  defp unit_score(0), do: {:ok, 0.0}
  defp unit_score(1), do: {:ok, 1.0}

  defp unit_score(value) when is_float(value) and value >= 0.0 and value <= 1.0,
    do: {:ok, value}

  defp unit_score(_value), do: :error

  defp format_score(value), do: value |> Float.round(2) |> to_string()

  defp parse_failure(text) do
    Logger.warning("[IntentConformance] Failed to parse judge JSON: #{clean_text(text, 200)}")

    failure("JSON parse error: #{clean_text(text, 100)}")
  end

  defp failure(detail) do
    %{score: 0.0, passed: false, detail: clean_text(detail, @max_detail_bytes)}
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp inspect_bounded(value) do
    value
    |> RetrievalSupport.bounded_external_reason()
    |> inspect(limit: 20, printable_limit: 400)
    |> clean_text(512)
  end

  defp clean_text(text, max_bytes) when is_binary(text) do
    prefix_size = min(byte_size(text), max_bytes)

    text
    |> binary_part(0, prefix_size)
    |> String.replace_invalid("")
  end
end
