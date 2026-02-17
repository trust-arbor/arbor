defmodule Arbor.Orchestrator.Handlers.FeedbackLoopHandler do
  @moduledoc """
  Handler that implements structured critique-then-revise loops with
  plateau detection for iterative LLM output improvement.

  Node attributes:
    - `source_key` - context key for initial content (default: "last_response")
    - `prompt` - the original task prompt (used for revision context)
    - `critique_prompt` - template for critique, `{content}` is replaced
      (default: "Review the following and identify specific improvements:\\n\\n{content}")
    - `max_iterations` - maximum loops (default: "3")
    - `score_threshold` - stop if score >= this (default: "0.8")
    - `scoring_method` - "length_ratio", "keyword_coverage", "structure",
      "combined" (default: "combined")
    - `reference_key` - context key with reference text for keyword_coverage
    - `plateau_window` - recent scores to check for plateau (default: "3")
    - `plateau_tolerance` - minimum improvement to not be plateau (default: "0.02")
    - `system_prompt` - optional system prompt for LLM calls

  Opts:
    - `:llm_backend` - fn(prompt, opts) -> {:ok, response} | {:error, reason}
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Context, Outcome}

  import Arbor.Orchestrator.Handlers.Helpers

  @default_max_iterations 3
  @default_threshold 0.8
  @default_plateau_window 3
  @default_plateau_tolerance 0.02

  @impl true
  def execute(node, context, _graph, opts) do
    source_key = Map.get(node.attrs, "source_key", "last_response")
    content = Context.get(context, source_key)

    unless content do
      raise "feedback.loop: source key '#{source_key}' not found in context"
    end

    max_iter = parse_int(Map.get(node.attrs, "max_iterations"), @default_max_iterations)
    threshold = parse_float(Map.get(node.attrs, "score_threshold"), @default_threshold)
    scoring = Map.get(node.attrs, "scoring_method", "combined")
    reference = if key = Map.get(node.attrs, "reference_key"), do: Context.get(context, key)
    plateau_window = parse_int(Map.get(node.attrs, "plateau_window"), @default_plateau_window)

    plateau_tol =
      parse_float(Map.get(node.attrs, "plateau_tolerance"), @default_plateau_tolerance)

    critique_template =
      Map.get(
        node.attrs,
        "critique_prompt",
        "Review the following and identify specific improvements:\n\n{content}"
      )

    task_prompt = Map.get(node.attrs, "prompt", "")
    system_prompt = Map.get(node.attrs, "system_prompt")
    llm_backend = Keyword.get(opts, :llm_backend)

    config = %{
      max_iter: max_iter,
      threshold: threshold,
      scoring: scoring,
      reference: reference,
      plateau_window: plateau_window,
      plateau_tol: plateau_tol,
      critique_template: critique_template,
      task_prompt: task_prompt,
      system_prompt: system_prompt,
      llm_backend: llm_backend
    }

    result = iterate(to_string(content), config, [], 0)
    build_outcome(result, node)
  rescue
    e ->
      %Outcome{
        status: :fail,
        failure_reason: "feedback.loop error: #{Exception.message(e)}"
      }
  end

  @impl true
  def idempotency, do: :side_effecting

  # --- Iteration loop ---

  defp iterate(content, config, scores, iteration) do
    score = score_content(content, config)
    scores = scores ++ [score]

    cond do
      score >= config.threshold ->
        {:done, content, scores, iteration + 1, false}

      iteration >= config.max_iter ->
        {:done, best_content(content, scores), scores, iteration, false}

      plateau?(scores, config.plateau_window, config.plateau_tol) ->
        {:done, content, scores, iteration + 1, true}

      true ->
        case critique_and_revise(content, config) do
          {:ok, revised} ->
            iterate(revised, config, scores, iteration + 1)

          {:error, _reason} ->
            {:done, content, scores, iteration + 1, false}
        end
    end
  end

  defp best_content(current, _scores), do: current

  # --- Critique and revise ---

  defp critique_and_revise(content, config) do
    critique_prompt = String.replace(config.critique_template, "{content}", content)

    with {:ok, critique} <- call_llm(critique_prompt, config) do
      revision_prompt =
        "Original task: #{config.task_prompt}\n\n" <>
          "Current version:\n#{content}\n\n" <>
          "Critique:\n#{critique}\n\n" <>
          "Please provide an improved version addressing the critique."

      call_llm(revision_prompt, config)
    end
  end

  defp call_llm(prompt, config) do
    if config.llm_backend do
      config.llm_backend.(prompt, system_prompt: config.system_prompt)
    else
      call_real_llm(prompt, config)
    end
  end

  defp call_real_llm(prompt, config) do
    if Code.ensure_loaded?(Arbor.Orchestrator.UnifiedLLM.Client) do
      request =
        struct!(Arbor.Orchestrator.UnifiedLLM.Request,
          provider: "claude_cli",
          model: "sonnet",
          messages: [apply(Arbor.Orchestrator.UnifiedLLM.Message, :user, [prompt])]
        )

      request =
        if config.system_prompt do
          sys = apply(Arbor.Orchestrator.UnifiedLLM.Message, :system, [config.system_prompt])
          %{request | messages: [sys | request.messages]}
        else
          request
        end

      case apply(Arbor.Orchestrator.UnifiedLLM.Client, :generate_with_tools, [request, []]) do
        {:ok, response} -> {:ok, response.content}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, "no LLM backend available"}
    end
  end

  # --- Scoring ---

  defp score_content(content, config) do
    case config.scoring do
      "length_ratio" -> score_length_ratio(content, config.reference)
      "keyword_coverage" -> score_keyword_coverage(content, config.reference)
      "structure" -> score_structure(content)
      "combined" -> score_combined(content, config.reference)
      _ -> score_combined(content, config.reference)
    end
  end

  defp score_length_ratio(content, reference) do
    target = if reference, do: String.length(reference), else: 500
    ratio = String.length(content) / max(target, 1)
    min(ratio, 1.0)
  end

  defp score_keyword_coverage(content, nil), do: score_structure(content)

  defp score_keyword_coverage(content, reference) do
    content_words = extract_words(content)
    ref_words = extract_words(reference)

    if MapSet.size(ref_words) == 0 and MapSet.size(content_words) == 0 do
      1.0
    else
      union = MapSet.union(content_words, ref_words)
      intersection = MapSet.intersection(content_words, ref_words)

      if MapSet.size(union) == 0, do: 0.0, else: MapSet.size(intersection) / MapSet.size(union)
    end
  end

  defp score_structure(content) do
    headers = length(Regex.scan(~r/^##?\s/m, content))
    code_blocks = length(Regex.scan(~r/```/, content)) |> div(2)
    list_items = length(Regex.scan(~r/^[-*]\s/m, content))
    paragraphs = content |> String.split(~r/\n\n+/) |> Enum.count(&(String.trim(&1) != ""))

    elements = headers + code_blocks + list_items + paragraphs
    min(elements / 10.0, 1.0)
  end

  defp score_combined(content, reference) do
    scores = [
      score_length_ratio(content, reference),
      score_structure(content)
    ]

    scores =
      if reference do
        [score_keyword_coverage(content, reference) | scores]
      else
        scores
      end

    Enum.sum(scores) / length(scores)
  end

  defp extract_words(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/)
    |> Enum.filter(&(String.length(&1) >= 3))
    |> MapSet.new()
  end

  # --- Plateau detection ---

  defp plateau?(scores, window, _tolerance) when length(scores) < window, do: false

  defp plateau?(scores, window, tolerance) do
    recent = Enum.take(scores, -window)
    max_score = Enum.max(recent)
    min_score = Enum.min(recent)
    max_score - min_score < tolerance
  end

  # --- Outcome building ---

  defp build_outcome({:done, content, scores, iterations, plateau_hit}, node) do
    final_score = List.last(scores)
    best_idx = scores |> Enum.with_index() |> Enum.max_by(&elem(&1, 0)) |> elem(1)

    %Outcome{
      status: :success,
      notes: "Completed #{iterations} iteration(s), final score: #{Float.round(final_score, 3)}",
      context_updates: %{
        "last_response" => content,
        "feedback.#{node.id}.iterations" => to_string(iterations),
        "feedback.#{node.id}.final_score" => to_string(Float.round(final_score, 4)),
        "feedback.#{node.id}.scores" => Jason.encode!(Enum.map(scores, &Float.round(&1, 4))),
        "feedback.#{node.id}.plateau_hit" => to_string(plateau_hit),
        "feedback.#{node.id}.best_iteration" => to_string(best_idx)
      }
    }
  end

  # --- Helpers ---

  defp parse_float(nil, default), do: default

  defp parse_float(val, default) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> default
    end
  end

  defp parse_float(val, _default) when is_number(val), do: val / 1
  defp parse_float(_, default), do: default
end
