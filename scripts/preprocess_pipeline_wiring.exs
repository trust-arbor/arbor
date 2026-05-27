#!/usr/bin/env elixir
#
# Preprocessor pipeline wiring test.
#
# Exercises the FULL preprocessor end-to-end, composing:
#   - the dormant gateway modules (PromptClassifier, IntentExtractor, VerificationPlan, PreprocessingLog)
#   - the eval-validated stages (complexity classifier, decomposer, Path 3 hybrid tool retrieval)
#
# Goal: confirm the whole pipeline composes, measure per-stage + cumulative latency,
# and surface any bit-rot — BEFORE wiring into production Session.send_message.
#
# This is a measurement harness, not a production module. Stages 3 (complexity)
# and 4 (decompose) are inline helpers mirroring the validated v2 prompts; the
# other stages call the real modules.
#
# Usage (from umbrella root):
#   mix run scripts/preprocess_pipeline_wiring.exs
#
# Requires: ollama running locally with granite4.1:3b, granite4:1b, mxbai-embed-large.

Application.ensure_all_started(:req)
Application.ensure_all_started(:arbor_gateway)
Application.ensure_all_started(:arbor_ai)
Application.ensure_all_started(:arbor_orchestrator)

defmodule PipelineWiring do
  alias Arbor.Gateway.{PromptClassifier, IntentExtractor, VerificationPlan, PreprocessingLog}
  alias Arbor.Orchestrator.Eval.Subjects.HybridRetrieval

  @ollama "http://localhost:11434/api/chat"
  @lmstudio "http://localhost:1234/v1/chat/completions"

  # Per-stage model + provider config (configurable per stage — Hysun's requirement).
  # needs_tools locked to gemma-4-e4b@q4 (LM Studio): 93.1% acc, 10 FN, 0 FP on the
  # corpus — beat Granite (which had 2× the dangerous false-negatives). The other
  # stages stay on Granite/Ollama. Revisit needs_tools when newer/faster models land.
  @stages %{
    needs_tools: %{provider: :lm_studio, model: "gemma-4-e4b-it@q4_k_xl"},
    complexity: %{provider: :ollama, model: "granite4.1:3b"},
    intent: %{provider: :ollama, model: "granite4.1:3b"},
    decompose: %{provider: :ollama, model: "granite4.1:3b"},
    rerank: %{provider: :ollama, model: "granite4:1b"}
  }

  @classifier_model @stages.complexity.model
  @decomposer_model @stages.decompose.model
  @intent_model @stages.intent.model
  @rerank_model @stages.rerank.model

  @complexity_prompt """
  You are a classifier. Given a user message sent to a personal AI coding assistant by a sophisticated technical user, classify it into one of three categories.

  IMPORTANT — the user often phrases directives conversationally:
    - "let's do X" / "yeah, let's X" = a DIRECTIVE to do X
    - "can we X" / "could you X" = a DIRECTIVE
    - "we should X" / "we need to X" = a DIRECTIVE
  A casual or first-person framing does NOT make a message non-actionable.

  SIMPLE — A single, direct action request. ONE thing for the assistant to do.
  MULTI_STEP — Multiple distinct actions in one message. Two or more separable asks.
  NON_ACTIONABLE — No specific action requested. Acknowledgments, status updates, musings.

  DECISION RULE — Is there any verb the assistant is being asked to do? If yes, SIMPLE or MULTI_STEP. If no, NON_ACTIONABLE.

  Respond with ONLY a JSON object: {"label": "SIMPLE" | "MULTI_STEP" | "NON_ACTIONABLE"}
  """

  @decomposer_prompt """
  You are a request decomposer. Split the user's message into independent sub-requests the ASSISTANT should perform.

  Do NOT extract: the user's own actions ("I'll do X"), tentative musings ("we could X... but let's see"), or invented details not in the prompt.

  Respond with ONLY: {"sub_requests": ["...", "..."]}
  """

  # needs_tools — the effort-tier gate. Locked model (gemma) is the empirical winner
  # with the GENERIC prompt; Arbor-grounding was tested and made it worse.
  @needs_tools_prompt """
  You classify a user message to a personal AI coding assistant.

  needs_tools (BOOLEAN): does fulfilling this request require the assistant to USE TOOLS
  — read/write files, run commands, inspect logs or external state, or investigate
  something — versus answering purely from conversation or the model's own knowledge?

    true  → requires touching files/commands/state or investigating. "commit this",
            "add X to the roadmap", "apply that change", "run the tests", AND any
            debugging/error report ("getting a 404", "the dialog won't accept clicks").
    false → answerable with no tools: greetings, acknowledgments, opinions, rewriting
            text the user supplied, explaining a concept, or providing information.

  needs_tools is about REQUIREMENT, not phrasing. A debugging/error report ALWAYS needs tools.

  Respond with ONLY JSON: {"needs_tools": true|false}
  """

  @needs_tools_re ~r/"needs_tools"\s*:\s*(true|false)/i

  # ---- LM Studio (OpenAI-compatible) helper — json_schema + reasoning_content fallback ----
  defp lmstudio_needs_tools(model, prompt, timeout \\ 30_000) do
    schema = %{
      type: "json_schema",
      json_schema: %{
        name: "needs_tools",
        strict: true,
        schema: %{
          type: "object",
          properties: %{needs_tools: %{type: "boolean"}},
          required: ["needs_tools"]
        }
      }
    }

    body = %{
      model: model,
      messages: [
        %{role: "system", content: @needs_tools_prompt},
        %{role: "user", content: prompt}
      ],
      temperature: 0.0,
      response_format: schema,
      max_tokens: 200
    }

    with {:ok, %{status: 200, body: %{"choices" => [%{"message" => msg} | _]}}} <-
           Req.post(@lmstudio, json: body, receive_timeout: timeout),
         text <- msg["content"] || msg["reasoning_content"] || "",
         [_, val] <- Regex.run(@needs_tools_re, text) do
      {:ok, String.downcase(val) == "true"}
    else
      _ -> {:error, :needs_tools_parse}
    end
  end

  # ---- Stage 2: needs_tools (the effort-tier gate) ----
  defp needs_tools(prompt) do
    %{provider: provider, model: model} = @stages.needs_tools

    case provider do
      :lm_studio ->
        case lmstudio_needs_tools(model, prompt) do
          {:ok, nt} -> nt
          # Fail SAFE: on error, assume tools are needed (don't wrongly fast-lane).
          {:error, _} -> true
        end

      :ollama ->
        case ollama_json(model, @needs_tools_prompt, prompt) do
          {:ok, %{"needs_tools" => nt}} when is_boolean(nt) -> nt
          _ -> true
        end
    end
  end

  # Operational tier DERIVED from needs_tools + complexity (not asked of the model).
  defp derive_tier(false, _complexity), do: "DIRECT"
  defp derive_tier(true, "MULTI_STEP"), do: "DEEP"
  defp derive_tier(true, "NON_ACTIONABLE"), do: "DEEP"
  defp derive_tier(true, _simple), do: "STANDARD"

  # ---- Inline Ollama chat helper for the eval-land stages ----
  defp ollama_json(model, system, user, timeout \\ 30_000) do
    body = %{
      model: model,
      messages: [%{role: "system", content: system}, %{role: "user", content: user}],
      stream: false,
      format: "json",
      think: false,
      options: %{temperature: 0.0, num_ctx: 8192}
    }

    case Req.post(@ollama, json: body, receive_timeout: timeout) do
      {:ok, %{status: 200, body: %{"message" => %{"content" => content}}}} ->
        case Jason.decode(content) do
          {:ok, parsed} -> {:ok, parsed}
          _ -> {:error, :bad_json}
        end

      other ->
        {:error, other}
    end
  end

  # ---- Stage 3: complexity ----
  defp classify_complexity(prompt) do
    case ollama_json(@classifier_model, @complexity_prompt, prompt) do
      {:ok, %{"label" => label}} -> label
      _ -> "UNKNOWN"
    end
  end

  # ---- Stage 4: decompose ----
  defp decompose(prompt) do
    case ollama_json(@decomposer_model, @decomposer_prompt, prompt) do
      {:ok, %{"sub_requests" => subs}} when is_list(subs) -> subs
      _ -> []
    end
  end

  # Over-decomposition guard: flag for plan-routing if too many distinct
  # sub-requests. NOT a silent cap — escalation routes to a plan path in
  # production. (Embedding-dedup was tried in v3 and merged nothing on the
  # real over-split pattern — over-granular-distinct, not near-duplicate — so
  # it was removed.)
  @escalation_threshold 6

  # ---- timing wrapper ----
  defp timed(fun) do
    t = System.monotonic_time(:millisecond)
    result = fun.()
    {result, System.monotonic_time(:millisecond) - t}
  end


  @doc """
  Run the full pipeline on one prompt (v3 ordering — needs_tools gated).

  sensitivity → needs_tools (gemma, the effort-tier gate)
    → DIRECT fast lane (needs_tools=false): skip complexity/intent/decompose/retrieval
    → actionable (needs_tools=true): complexity (→ STANDARD/DEEP + gate decompose),
       then intent ‖ (decompose → parallel retrieval), then verification.
  Total is WALL-CLOCK (intent ‖ retrieval overlap).
  """
  def run_pipeline(prompt) do
    # Stage 1: sensitivity (always, ~1ms)
    {classification, t1} = timed(fn -> PromptClassifier.classify(prompt) end)

    # Stage 2: needs_tools — the effort-tier GATE (gemma-4-e4b@q4 via LM Studio)
    {nt, t_nt} = timed(fn -> needs_tools(prompt) end)

    if nt == false do
      # DIRECT fast lane: no complexity, no intent, no decompose, no retrieval.
      tier = "DIRECT"
      total = t1 + t_nt
      log_res = log(prompt, classification, tier, total)

      %{
        prompt: prompt,
        needs_tools: false,
        complexity: :skipped,
        tier: tier,
        stages: %{
          sensitivity: {classification.overall_sensitivity, classification.routing_recommendation, t1},
          needs_tools: {false, t_nt},
          complexity: {:skipped, 0},
          intent: {:skipped, 0},
          decompose: {[], 0},
          retrieval: {:skipped, 0},
          verification: {:skipped, 0},
          log: log_res
        },
        total_ms: total
      }
    else
      # Actionable: complexity derives STANDARD vs DEEP and gates decompose.
      {complexity, t2} = timed(fn -> classify_complexity(prompt) end)
      tier = derive_tier(true, complexity)

      # Run intent ‖ (decompose → parallel retrieval) concurrently.
      {block_result, t_block} =
        timed(fn ->
          intent_task =
            Task.async(fn ->
              timed(fn ->
                IntentExtractor.extract(prompt,
                  classification: classification,
                  provider: :ollama,
                  model: @intent_model,
                  timeout: 30_000
                )
              end)
            end)

          # decompose (MULTI_STEP only) → flag escalation if too many distinct asks
          {{sub_requests, dedup}, t_dec} =
            if complexity == "MULTI_STEP" do
              timed(fn ->
                raw = decompose(prompt)
                escalate = length(raw) > @escalation_threshold
                {raw, %{count: length(raw), escalate: escalate}}
              end)
            else
              {{[prompt], %{count: 1, escalate: false}}, 0}
            end

          {retrieval, t_ret} =
            timed(fn ->
              sub_requests
              |> Task.async_stream(
                fn sub ->
                  case HybridRetrieval.run(%{"prompt" => sub}, model: @rerank_model) do
                    {:ok, %{retrieved: r}} -> {sub, Enum.map(r, & &1.module)}
                    {:error, e} -> {sub, {:error, e}}
                  end
                end,
                max_concurrency: 8,
                timeout: 60_000
              )
              |> Enum.map(fn {:ok, res} -> res end)
            end)

          {intent_res, t_intent} = Task.await(intent_task, 60_000)

          %{
            intent: intent_res, t_intent: t_intent,
            sub_requests: sub_requests, t_dec: t_dec, dedup: dedup,
            retrieval: retrieval, t_ret: t_ret
          }
        end)

      intent =
        case block_result.intent do
          {:ok, i} -> i
          {:error, reason} -> {:error, reason}
        end

      {plan, _t_ver} =
        timed(fn ->
          case intent do
            {:error, _} -> :skipped
            i -> VerificationPlan.from_intent(i)
          end
        end)

      total = t1 + t_nt + t2 + t_block
      log_res = log(prompt, classification, tier, total)

      %{
        prompt: prompt,
        needs_tools: true,
        complexity: complexity,
        tier: tier,
        stages: %{
          sensitivity: {classification.overall_sensitivity, classification.routing_recommendation, t1},
          needs_tools: {true, t_nt},
          complexity: {complexity, t2},
          intent: {intent, block_result.t_intent},
          decompose: {block_result.sub_requests, block_result.t_dec},
          retrieval: {block_result.retrieval, block_result.t_ret},
          verification: {plan, 0},
          log: log_res
        },
        dedup: block_result.dedup,
        block_ms: t_block,
        total_ms: total
      }
    end
  end

  defp log(prompt, classification, tier, total) do
    PreprocessingLog.record(%{
      prompt_hash: :crypto.hash(:sha256, prompt) |> Base.encode16(),
      classification: classification.overall_sensitivity,
      tier: tier,
      total_ms: total
    })

    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  def print_trace(trace, expected_label) do
    s = trace.stages
    {sens, route, t1} = s.sensitivity
    {nt, t_nt} = s.needs_tools
    {complexity, t2} = s.complexity
    {intent, t_int} = s.intent
    {subs, t_dec} = s.decompose
    {retrieval, t_ret} = s.retrieval

    IO.puts("\n" <> String.duplicate("─", 78))
    IO.puts("PROMPT (#{expected_label}): #{String.slice(trace.prompt, 0, 90)}")
    IO.puts("  [1] sensitivity:  #{sens} → #{route}  (#{t1}ms)")
    IO.puts("  [2] needs_tools:  #{nt}  (#{t_nt}ms)  → tier=#{trace.tier}")

    if trace.tier == "DIRECT" do
      IO.puts("      → DIRECT fast lane: complexity/intent/decompose/retrieval all skipped")
    else
      IO.puts("  [3] complexity:   #{complexity}  (#{t2}ms)  [expected: #{expected_label}]")
      block = Map.get(trace, :block_ms, 0)
      IO.puts("      ── concurrent block (#{block}ms wall-clock) ──")

      case intent do
        {:error, reason} -> IO.puts("  [4] intent:       ERROR #{inspect(reason)}  (#{t_int}ms)")
        i -> IO.puts("  [4] intent:       goal=#{inspect(String.slice(i.goal, 0, 55))} risk=#{i.risk_level}  (#{t_int}ms)")
      end

      if complexity == "MULTI_STEP" do
        d = Map.get(trace, :dedup, %{count: length(subs), escalate: false})
        esc = if d.escalate, do: "  ⚠️ ESCALATE (>6 → handle as plan)", else: ""
        IO.puts("  [5] decompose:    #{d.count} sub-requests  (#{t_dec}ms)#{esc}")
        Enum.each(subs, fn sr -> IO.puts("        - #{String.slice(sr, 0, 68)}") end)
      end

      case retrieval do
        results when is_list(results) ->
          IO.puts("  [6] retrieval:    #{length(results)} sub-route(s) parallel  (#{t_ret}ms)")
          Enum.each(results, fn
            {sub, mods} when is_list(mods) ->
              IO.puts("        #{String.slice(sub, 0, 40)} → #{Enum.take(mods, 3) |> Enum.join(", ")}")
            {sub, err} ->
              IO.puts("        #{String.slice(sub, 0, 40)} → #{inspect(err)}")
          end)
        _ -> :ok
      end

      plan_desc = if elem(s.verification, 0) == :skipped, do: "skipped", else: "#{length(elem(s.verification, 0).checks)} checks"
      IO.puts("  [7] verification: #{plan_desc}")
    end

    IO.puts("  [7] log:          #{inspect(s.log)}")
    IO.puts("  TOTAL (wall-clock): #{trace.total_ms}ms")
  end
end

# ---- Load a small representative sample from the labeled corpus ----
corpus_path = Path.expand("~/.claude/arbor-personal/eval_corpus/hysun_corpus_sample.jsonl")

samples =
  corpus_path
  |> File.stream!()
  |> Enum.map(&Jason.decode!/1)
  |> Enum.group_by(& &1["label"])
  |> Enum.flat_map(fn {_label, recs} -> Enum.take(recs, 3) end)

IO.puts("Preprocessor pipeline wiring test — #{length(samples)} prompts (3 per label)\n")

traces =
  Enum.map(samples, fn rec ->
    trace = PipelineWiring.run_pipeline(rec["content"])
    PipelineWiring.print_trace(trace, rec["label"])
    {rec["label"], trace}
  end)

# ---- Summary ----
IO.puts("\n" <> String.duplicate("═", 78))
IO.puts("SUMMARY")

stage_keys = [:sensitivity, :needs_tools, :complexity, :intent, :decompose, :retrieval, :verification]

IO.puts("\nPer-stage latency (avg ms across #{length(traces)} prompts):")

for key <- stage_keys do
  times =
    Enum.map(traces, fn {_l, t} ->
      case Map.get(t.stages, key) do
        tuple when is_tuple(tuple) -> elem(tuple, tuple_size(tuple) - 1)
        _ -> 0
      end
    end)

  avg = Enum.sum(times) / length(times)
  IO.puts("  #{String.pad_trailing(to_string(key), 14)} #{Float.round(avg, 0)}ms")
end

totals = Enum.map(traces, fn {_l, t} -> t.total_ms end)
IO.puts("\nNote: intent ‖ retrieval run concurrently for actionable prompts, so total is wall-clock (< sum of stages).")
IO.puts("Total latency: avg=#{round(Enum.sum(totals) / length(totals))}ms  min=#{Enum.min(totals)}ms  max=#{Enum.max(totals)}ms")

# Wall-clock total by DERIVED tier (shows the DIRECT fast-lane win)
IO.puts("\nWall-clock total by effort tier:")
traces
|> Enum.group_by(fn {_l, t} -> t.tier end)
|> Enum.each(fn {tier, group} ->
  ts = Enum.map(group, fn {_l, t} -> t.total_ms end)
  IO.puts("  #{String.pad_trailing(tier, 10)} n=#{length(ts)}  avg=#{round(Enum.sum(ts) / length(ts))}ms")
end)

# How many prompts hit the DIRECT fast lane
direct = Enum.count(traces, fn {_l, t} -> t.tier == "DIRECT" end)
IO.puts("\nDIRECT fast lane: #{direct}/#{length(traces)} prompts skipped intent+retrieval")

IO.puts("\nWiring test complete.")
