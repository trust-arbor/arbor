defmodule Arbor.Agent.Eval.EffectiveWindowEval do
  @moduledoc """
  Discovers the effective context window per model — the fill level
  where reasoning quality degrades, measured via fact recall accuracy.

  Seeds verifiable facts across a conversation context at various fill levels,
  then measures how many facts the model correctly retrieves. The "effective window"
  is the highest fill level where accuracy remains above a configurable threshold.

  ## Usage

      # Run for a single model
      EffectiveWindowEval.run(models: [{"openrouter", "anthropic/claude-3-5-haiku-latest"}])

      # Quick test with fewer facts
      EffectiveWindowEval.run(
        models: [{"openrouter", "anthropic/claude-3-5-haiku-latest"}],
        num_facts: 5,
        fill_levels: [0.1, 0.5]
      )

  ## Persistence

  Results are stored via EvalRun/EvalResult:
    - One EvalRun per model (domain: "effective_window")
    - One EvalResult per fill level within that run
  """

  alias Arbor.Agent.ContextCompactor
  alias Arbor.Agent.Eval.FactCorpus

  require Logger

  @default_fill_levels [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
  @accuracy_threshold 0.9
  @safety_margin 0.9
  @default_timeout 120_000

  # ── Public API ──────────────────────────────────────────────────

  @doc """
  Run effective window eval for one or more models.

  ## Options

    * `:models` - List of `{provider, model}` tuples (required)
    * `:fill_levels` - Fill percentages to test (default: 10%-100% by 10%)
    * `:num_facts` - Number of verifiable facts to seed (default: 30)
    * `:accuracy_threshold` - Min accuracy to consider "effective" (default: 0.9)
    * `:timeout` - Per-request timeout in ms (default: 120_000)
    * `:persist` - Whether to persist results (default: true)
    * `:context_window` - Override context window size (tokens)
    * `:tag` - Tag for identifying runs
  """
  @spec run(keyword()) :: {:ok, [map()]} | {:error, term()}
  def run(opts \\ []) do
    models = Keyword.fetch!(opts, :models)
    fill_levels = Keyword.get(opts, :fill_levels, @default_fill_levels)
    num_facts = Keyword.get(opts, :num_facts, 30)
    threshold = Keyword.get(opts, :accuracy_threshold, @accuracy_threshold)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    persist = Keyword.get(opts, :persist, true)
    context_window_override = Keyword.get(opts, :context_window)
    tag = Keyword.get(opts, :tag)

    facts = FactCorpus.generate_facts(num_facts)

    Logger.info(
      "[EffectiveWindowEval] Starting: #{length(models)} model(s), " <>
        "#{length(fill_levels)} fill level(s), #{num_facts} facts"
    )

    results =
      Enum.map(models, fn {provider, model} ->
        context_window = context_window_override || get_context_window(model)

        Logger.info(
          "[EffectiveWindowEval] Model: #{model} (#{provider}), context_window: #{context_window}"
        )

        fill_results =
          Enum.map(fill_levels, fn fill ->
            run_single(provider, model, fill, facts, context_window, timeout: timeout)
          end)

        effective = find_effective_window(fill_results, threshold)
        recommended_threshold = if effective, do: Float.round(effective * @safety_margin, 2)

        model_result = %{
          model: model,
          provider: provider,
          context_window: context_window,
          num_facts: num_facts,
          results: fill_results,
          effective_window: effective,
          recommended_threshold: recommended_threshold
        }

        if persist do
          persist_results(model_result, tag)
        end

        print_model_results(model_result)

        model_result
      end)

    {:ok, results}
  end

  @doc """
  Run a single fill level for a single model.

  Returns a map with `:fill_level`, `:accuracy`, `:per_fact_scores`,
  `:timing_ms`, `:token_count`, and `:error` (if any).
  """
  @spec run_single(String.t(), String.t(), float(), [map()], non_neg_integer(), keyword()) ::
          map()
  @max_output_tokens 4000
  # Safety margin for token estimation error (our 4-chars/token heuristic
  # undercounts vs real BPE tokenizers by ~12%)
  @token_estimation_margin 0.85

  def run_single(provider, model, fill_level, facts, context_window, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    # Reserve max_tokens for response, then apply 15% safety margin
    # to account for token estimation drift across different tokenizers
    input_budget = trunc((context_window - @max_output_tokens) * @token_estimation_margin)
    target_tokens = trunc(input_budget * fill_level)

    Logger.info(
      "[EffectiveWindowEval] Fill #{trunc(fill_level * 100)}% " <>
        "(#{target_tokens} tokens) for #{model}"
    )

    messages = FactCorpus.build_context(facts, target_tokens)
    actual_tokens = count_message_tokens(messages)

    start = System.monotonic_time(:millisecond)

    case call_llm(provider, model, messages, timeout) do
      {:ok, response_text} ->
        elapsed = System.monotonic_time(:millisecond) - start
        scores = score_recall(response_text, facts)
        accuracy = mean(Enum.map(scores, fn {_id, score} -> score end))

        Logger.info(
          "[EffectiveWindowEval] Fill #{trunc(fill_level * 100)}%: " <>
            "accuracy=#{Float.round(accuracy, 3)}, time=#{elapsed}ms"
        )

        %{
          fill_level: fill_level,
          accuracy: Float.round(accuracy, 4),
          per_fact_scores: scores,
          timing_ms: elapsed,
          token_count: actual_tokens,
          error: nil
        }

      {:error, reason} ->
        elapsed = System.monotonic_time(:millisecond) - start

        Logger.warning(
          "[EffectiveWindowEval] Fill #{trunc(fill_level * 100)}% failed: #{inspect(reason)}"
        )

        %{
          fill_level: fill_level,
          accuracy: 0.0,
          per_fact_scores: [],
          timing_ms: elapsed,
          token_count: actual_tokens,
          error: inspect(reason)
        }
    end
  end

  @doc """
  Score model responses against ground truth facts.

  Parses the model's response (expected as numbered answers) and compares
  each answer against the fact's expected answer.

  Returns a list of `{fact_id, score}` tuples where score is:
  - 1.0 for exact match (answer contained in response line)
  - 0.5 for partial match (at least half the answer words found)
  - 0.0 for wrong/UNKNOWN/missing
  """
  @spec score_recall(String.t(), [map()]) :: [{String.t(), float()}]
  def score_recall(response_text, facts) do
    # Parse numbered responses
    lines = parse_response_lines(response_text)

    facts
    |> Enum.with_index(1)
    |> Enum.map(fn {fact, idx} ->
      response_line = Map.get(lines, idx, "")
      score = score_single_fact(response_line, fact.answer)
      {fact.id, score}
    end)
  end

  @doc """
  Determine effective window from accuracy curve.

  Finds the highest fill level where accuracy >= threshold.
  Returns nil if no fill level meets the threshold.
  """
  @spec find_effective_window([map()], float()) :: float() | nil
  def find_effective_window(fill_results, threshold \\ @accuracy_threshold) do
    fill_results
    |> Enum.filter(fn r -> r.error == nil and r.accuracy >= threshold end)
    |> Enum.map(& &1.fill_level)
    |> Enum.max(fn -> nil end)
  end

  # ── LLM Call ──────────────────────────────────────────────────

  defp call_llm(provider, model, messages, timeout) do
    client_mod = Module.concat([:Arbor, :Orchestrator, :UnifiedLLM, :Client])
    request_mod = Module.concat([:Arbor, :Orchestrator, :UnifiedLLM, :Request])
    message_mod = Module.concat([:Arbor, :Orchestrator, :UnifiedLLM, :Message])

    if Code.ensure_loaded?(client_mod) and Code.ensure_loaded?(request_mod) and
         Code.ensure_loaded?(message_mod) do
      # Convert our plain maps to Message structs
      llm_messages =
        Enum.map(messages, fn msg ->
          role = msg.role
          content = msg.content
          struct(message_mod, %{role: role, content: content})
        end)

      request =
        struct(request_mod, %{
          provider: provider,
          model: model,
          messages: llm_messages,
          max_tokens: @max_output_tokens,
          temperature: 0.0
        })

      client = apply(client_mod, :from_env, [[]])

      case apply(client_mod, :complete, [client, request, [timeout: timeout]]) do
        {:ok, response} ->
          text = Map.get(response, :text, "")
          {:ok, text}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :unified_llm_unavailable}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # ── Scoring ──────────────────────────────────────────────────

  defp parse_response_lines(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case Regex.run(~r/^\s*(\d+)\.\s*(.+)$/m, String.trim(line)) do
        [_, num_str, answer] ->
          case Integer.parse(num_str) do
            {num, _} -> Map.put(acc, num, String.trim(answer))
            :error -> acc
          end

        _ ->
          acc
      end
    end)
  end

  defp parse_response_lines(_), do: %{}

  defp score_single_fact(response_line, expected_answer) do
    response_lower = String.downcase(response_line)
    expected_lower = String.downcase(expected_answer)

    cond do
      # UNKNOWN or empty
      response_line == "" or String.contains?(response_lower, "unknown") ->
        0.0

      # Exact match — expected answer appears in the response
      String.contains?(response_lower, expected_lower) ->
        1.0

      # Partial match — at least half the answer words are present
      partial_match?(response_lower, expected_lower) ->
        0.5

      true ->
        0.0
    end
  end

  defp partial_match?(response, expected) do
    expected_words =
      expected
      |> String.split(~r/[\s,\-\/]+/)
      |> Enum.reject(&(&1 == ""))

    if expected_words == [] do
      false
    else
      matches = Enum.count(expected_words, &String.contains?(response, &1))
      matches / length(expected_words) >= 0.5
    end
  end

  # ── Context Window Lookup ──────────────────────────────────────

  defp get_context_window(model) do
    # Try LLMDB first, then TokenBudget, then heuristic defaults
    context_from_llmdb(model) ||
      context_from_token_budget(model) ||
      context_from_heuristic(model)
  end

  defp context_from_llmdb(model) do
    if Code.ensure_loaded?(LLMDB) do
      # Try common providers
      providers = [:anthropic, :openai, :google, :openrouter, :xai]

      Enum.find_value(providers, fn provider ->
        case apply(LLMDB, :model, [provider, model]) do
          {:ok, %{limits: %{context: ctx}}} when is_integer(ctx) and ctx > 0 -> ctx
          _ -> nil
        end
      end)
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp context_from_token_budget(model) do
    mod = Module.concat([:Arbor, :Memory, :TokenBudget])

    if Code.ensure_loaded?(mod) and function_exported?(mod, :model_context_size, 1) do
      size = apply(mod, :model_context_size, [model])
      # TokenBudget returns 100_000 as default — only trust if it's different
      if size != 100_000, do: size, else: nil
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp context_from_heuristic(model) do
    cond do
      String.contains?(model, "claude") -> 200_000
      String.contains?(model, "gpt-4o") -> 128_000
      String.contains?(model, "gemini") -> 1_000_000
      String.contains?(model, "haiku") -> 200_000
      String.contains?(model, "sonnet") -> 200_000
      true -> 100_000
    end
  end

  # ── Helpers ──────────────────────────────────────────────────

  defp count_message_tokens(messages) do
    Enum.reduce(messages, 0, fn msg, acc ->
      acc + ContextCompactor.estimate_tokens(msg)
    end)
  end

  defp mean([]), do: 0.0
  defp mean(values), do: Enum.sum(values) / length(values)

  # ── Persistence ──────────────────────────────────────────────

  defp persist_results(model_result, tag) do
    run_id = "ew_#{sanitize(model_result.model)}_#{:erlang.unique_integer([:positive])}"

    total_duration =
      model_result.results
      |> Enum.map(& &1.timing_ms)
      |> Enum.sum()

    run_attrs = %{
      id: run_id,
      domain: "effective_window",
      model: model_result.model,
      provider: model_result.provider,
      dataset: "fact_recall_#{model_result.num_facts}",
      graders: ["fact_recall_scoring"],
      sample_count: length(model_result.results),
      duration_ms: round(total_duration),
      metrics: %{
        "effective_window" => model_result.effective_window,
        "recommended_threshold" => model_result.recommended_threshold,
        "context_window" => model_result.context_window,
        "num_facts" => model_result.num_facts,
        "fill_levels_tested" => length(model_result.results)
      },
      config: %{
        "model" => model_result.model,
        "provider" => model_result.provider,
        "context_window" => model_result.context_window,
        "num_facts" => model_result.num_facts
      },
      metadata: if(tag, do: %{"tag" => tag}, else: %{}),
      status: "completed"
    }

    case persist_run(run_attrs) do
      {:ok, _} ->
        persist_fill_results(run_id, model_result.results)
        Logger.debug("[EffectiveWindowEval] Persisted run #{run_id}")

      {:error, reason} ->
        Logger.warning("[EffectiveWindowEval] Failed to persist run: #{inspect(reason)}")
    end
  end

  defp persist_fill_results(run_id, results) do
    result_attrs =
      Enum.map(results, fn r ->
        per_fact =
          case r.per_fact_scores do
            scores when is_list(scores) ->
              Map.new(scores, fn {id, score} -> {id, score} end)

            _ ->
              %{}
          end

        %{
          id: "#{run_id}_fill#{trunc(r.fill_level * 100)}",
          run_id: run_id,
          sample_id: "fill_#{trunc(r.fill_level * 100)}pct",
          input: "#{trunc(r.fill_level * 100)}% context fill",
          actual: "accuracy: #{r.accuracy}",
          passed: r.error == nil and r.accuracy >= @accuracy_threshold,
          scores: Map.merge(per_fact, %{"accuracy" => r.accuracy}),
          duration_ms: r.timing_ms,
          tokens_generated: 0,
          metadata: %{
            "fill_level" => r.fill_level,
            "accuracy" => r.accuracy,
            "token_count" => r.token_count,
            "error" => r.error
          }
        }
      end)

    persist_results_batch(result_attrs)
  end

  defp persist_run(attrs) do
    if Code.ensure_loaded?(Arbor.Persistence) and
         function_exported?(Arbor.Persistence, :insert_eval_run, 1) do
      apply(Arbor.Persistence, :insert_eval_run, [attrs])
    else
      {:error, :persistence_unavailable}
    end
  rescue
    _ -> {:error, :persistence_error}
  catch
    :exit, _ -> {:error, :persistence_unavailable}
  end

  defp persist_results_batch(results) do
    if Code.ensure_loaded?(Arbor.Persistence) and
         function_exported?(Arbor.Persistence, :insert_eval_results_batch, 1) do
      apply(Arbor.Persistence, :insert_eval_results_batch, [results])
    else
      {:error, :persistence_unavailable}
    end
  rescue
    _ -> {:error, :persistence_error}
  catch
    :exit, _ -> {:error, :persistence_unavailable}
  end

  defp sanitize(model_name) do
    model_name
    |> String.replace(~r/[^a-zA-Z0-9]/, "_")
    |> String.slice(0, 40)
  end

  # ── Output ──────────────────────────────────────────────────

  defp print_model_results(result) do
    IO.puts("\n== #{result.model} (#{result.provider}) ==")
    IO.puts("Context window: #{result.context_window} tokens")
    IO.puts("")

    IO.puts(
      String.pad_trailing("Fill%", 8) <>
        String.pad_trailing("Accuracy", 10) <>
        String.pad_trailing("Time", 10) <>
        String.pad_trailing("Tokens", 10) <>
        "Status"
    )

    IO.puts(String.duplicate("-", 50))

    for r <- result.results do
      status =
        cond do
          r.error != nil -> "ERROR"
          r.accuracy >= @accuracy_threshold -> "PASS"
          true -> "DEGRADED"
        end

      IO.puts(
        String.pad_trailing("#{trunc(r.fill_level * 100)}%", 8) <>
          String.pad_trailing("#{Float.round(r.accuracy, 3)}", 10) <>
          String.pad_trailing("#{r.timing_ms}ms", 10) <>
          String.pad_trailing("#{r.token_count}", 10) <>
          status
      )
    end

    IO.puts("")

    if result.effective_window do
      IO.puts("Effective window: #{trunc(result.effective_window * 100)}%")
      IO.puts("Recommended compaction threshold: #{result.recommended_threshold}")
    else
      IO.puts("Effective window: NONE (no fill level met accuracy threshold)")
    end

    IO.puts("")
  end
end
