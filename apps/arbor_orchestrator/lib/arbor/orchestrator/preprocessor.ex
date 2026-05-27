defmodule Arbor.Orchestrator.Preprocessor do
  @moduledoc """
  Pre-turn preprocessor pipeline. Runs before a turn's LLM call and returns
  enrichment that `Session` attaches to the turn context under `session.preprocessor.*`.

  **Disabled by default, fails open.** Controlled by `Arbor.Orchestrator.Config`
  (`preprocessor_enabled?`). Any stage error degrades gracefully — the turn
  proceeds without that stage's output rather than failing.

  ## Stages

  1. **sensitivity** — `Arbor.Gateway.PromptClassifier` (PII/secret scan → routing).
  2. **needs_tools** — small LLM judges whether fulfilling the request needs tools
     (files/commands/state/investigation) vs. a pure conversational answer. This is
     the effort-tier gate. Locked model: `gemma-4-e4b-it@q4` (LM Studio).
  3. **complexity** — (actionable only) SIMPLE / MULTI_STEP / NON_ACTIONABLE.
  4. **intent** — (actionable only) `Arbor.Gateway.IntentExtractor`
     (goal / success_criteria / constraints / risk_level).
  5. **tier** — DERIVED: `needs_tools=false → DIRECT`; `true + SIMPLE → STANDARD`;
     `true + (MULTI_STEP|NON_ACTIONABLE) → DEEP`.

  Optional, config-gated (default off): **decompose** (MULTI_STEP → sub-requests)
  and **retrieval** (JIT tool injection) — these need an action index and are the
  heaviest stages.

  ## Architectural notes

  `arbor_orchestrator` does NOT depend on `arbor_gateway`/`arbor_ai` at compile time
  (hierarchy). Gateway modules are resolved at RUNTIME (`Code.ensure_loaded?` +
  `function_exported?`) per the config, so there is no cross-library compile dep.
  LLM calls go through `Req` (external) directly to Ollama / LM Studio.

  ## What this does NOT do

  It RUNS the pipeline and EXPOSES results in context. It does not (yet) make the
  engine ACT on them (fast-lane skip, tool injection into the LLM call). Consuming
  `session.preprocessor.*` downstream is a separate step.

  See `docs/arbor/PREPROCESSOR.md`.
  """

  require Logger

  alias Arbor.Orchestrator.Config

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

  @complexity_prompt """
  Classify a user message to a personal AI coding assistant into ONE category.

  SIMPLE — one direct action. MULTI_STEP — multiple distinct actions.
  NON_ACTIONABLE — no action requested (acknowledgment, status, musing).

  A casual or first-person directive ("let's X", "we should X") still counts as a directive.

  Respond with ONLY: {"label": "SIMPLE" | "MULTI_STEP" | "NON_ACTIONABLE"}
  """

  @needs_tools_re ~r/"needs_tools"\s*:\s*(true|false)/i

  @doc """
  Run the preprocessor for `prompt`. Returns `{:ok, map}` with string keys suitable
  for merging into turn context, or `{:ok, %{}}` when disabled. Never returns
  `{:error, _}` — it fails open.

  `classification_opts` may carry `:agent_id`/`:trust_tier` etc. for future use.
  """
  @spec run(String.t(), keyword()) :: {:ok, map()}
  def run(prompt, _opts \\ []) when is_binary(prompt) do
    if Config.preprocessor_enabled?() do
      # Telemetry span: emits [:arbor, :preprocessor, :run, :start | :stop | :exception]
      # with :duration. Per-stage timings come from [:arbor, :preprocessor, :stage].
      # Attach a handler (see Arbor.Signals.Telemetry) to profile turns.
      :telemetry.span([:arbor, :preprocessor, :run], %{}, fn ->
        result = do_run(prompt)

        {{:ok, result},
         %{
           tier: result["tier"],
           needs_tools: result["needs_tools"],
           retrieved_count: length(result["retrieved_tools"] || [])
         }}
      end)
    else
      {:ok, %{}}
    end
  rescue
    e ->
      Logger.warning("[Preprocessor] failed open: #{Exception.message(e)}")
      {:ok, %{}}
  end

  defp do_run(prompt) do
    cfg = Config.preprocessor()

    sensitivity = timed_stage(:sensitivity, fn -> sensitivity(prompt, cfg) end, nil)
    nt = timed_stage(:needs_tools, fn -> needs_tools(prompt, cfg) end, true)

    base = %{
      "enabled" => true,
      "sensitivity" => sensitivity,
      "needs_tools" => nt
    }

    if nt == false do
      Map.put(base, "tier", "DIRECT")
    else
      # complexity, intent, and retrieval are independent — run concurrently so the
      # actionable-turn cost is the slowest stage (intent ~2.2s), not their sum.
      await = (cfg[:timeout_ms] || 30_000) + 5_000

      c_task =
        Task.async(fn ->
          timed_stage(:complexity, fn -> complexity(prompt, cfg) end, "SIMPLE")
        end)

      r_task =
        Task.async(fn ->
          timed_stage(:retrieval, fn -> retrieve_tool_names(prompt, cfg) end, [])
        end)

      # intent (goal/risk_level) is the slowest stage (~2-4s) and is currently
      # UNCONSUMED downstream — gated off by default. Enable it once something reads it.
      i_task =
        if Keyword.get(cfg[:intent] || [], :enabled, false) do
          Task.async(fn ->
            timed_stage(:intent, fn -> intent(prompt, sensitivity, cfg) end, nil)
          end)
        else
          nil
        end

      complexity = task_await(c_task, await, "SIMPLE")
      retrieved = task_await(r_task, await, [])
      intent = if i_task, do: task_await(i_task, await, nil), else: nil

      enriched =
        base
        |> Map.put("complexity", complexity)
        |> Map.put("tier", derive_tier(true, complexity))
        |> Map.put("intent", intent)

      case retrieved do
        [] -> enriched
        names -> Map.put(enriched, "retrieved_tools", names)
      end
    end
  end

  defp task_await(task, timeout, default) do
    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> default
    end
  end

  # ---- tier derivation ----
  @doc false
  def derive_tier(false, _), do: "DIRECT"
  def derive_tier(true, "MULTI_STEP"), do: "DEEP"
  def derive_tier(true, "NON_ACTIONABLE"), do: "DEEP"
  def derive_tier(true, _simple), do: "STANDARD"

  @doc """
  Decide how the turn's tool list should be overridden based on preprocessor output.

  This is how the engine CONSUMES the preprocessor. The result is applied by the
  Session to `context["session.tools"]`, which `LlmHandler.resolve_tools/3` reads
  first — so it controls exactly which tools the LLM call sees.

  Returns:
    * `{:override, tools}` — set `session.tools` to `tools` for this turn
    * `:no_override` — leave the session's normal tool resolution unchanged

  Decision order:
    1. If the preprocessor produced a `retrieved_tools` list (JIT tool injection),
       use it verbatim. (Retrieval isn't populated in production yet — this is the
       ready hook.)
    2. Else if `tier == "DIRECT"` and `direct_skips_tools?` is true, override to `[]`
       — the no-tools fast lane: the LLM answers directly, skipping the tool loop.
    3. Else no override.

  ## Options
    * `:direct_skips_tools?` (default true) — whether DIRECT empties the tool list.
      Set false to keep DIRECT advisory-only (insurance against the classifier's
      residual false-negatives, which would otherwise leave a tool-needing turn
      tool-less).
  """
  @spec tool_override(map(), keyword()) :: {:override, list()} | :no_override
  def tool_override(preproc, opts \\ []) do
    direct_skips? = Keyword.get(opts, :direct_skips_tools?, true)

    cond do
      is_list(preproc["retrieved_tools"]) -> {:override, preproc["retrieved_tools"]}
      direct_skips? and preproc["tier"] == "DIRECT" -> {:override, []}
      true -> :no_override
    end
  end

  # ---- Stage 1: sensitivity (runtime-resolved gateway module) ----
  defp sensitivity(prompt, cfg) do
    mod = cfg[:prompt_classifier]

    if loaded?(mod, :classify, 1) do
      c = mod.classify(prompt)

      %{
        "level" => to_string(c.overall_sensitivity),
        "routing" => to_string(c.routing_recommendation)
      }
    else
      nil
    end
  end

  # ---- Stage 2: needs_tools (LM Studio / Ollama via Req) ----
  defp needs_tools(prompt, cfg) do
    stage = cfg[:needs_tools]
    timeout = cfg[:timeout_ms] || 30_000

    case stage[:provider] do
      :lm_studio -> lm_studio_needs_tools(stage, prompt, timeout)
      :ollama -> ollama_needs_tools(stage, prompt, timeout)
      _ -> true
    end
  end

  defp lm_studio_needs_tools(stage, prompt, timeout) do
    url = (stage[:base_url] || "http://localhost:1234/v1") <> "/chat/completions"

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
      model: stage[:model],
      messages: chat(@needs_tools_prompt, prompt),
      temperature: 0.0,
      response_format: schema,
      max_tokens: 200
    }

    with {:ok, %{status: 200, body: %{"choices" => [%{"message" => msg} | _]}}} <-
           Req.post(url, json: body, receive_timeout: timeout),
         text <- msg["content"] || msg["reasoning_content"] || "",
         [_, val] <- Regex.run(@needs_tools_re, text) do
      String.downcase(val) == "true"
    else
      # Fail SAFE: assume tools needed (don't wrongly route to the no-tools fast lane).
      _ -> true
    end
  end

  defp ollama_needs_tools(stage, prompt, timeout) do
    case ollama_json(stage, @needs_tools_prompt, prompt, timeout) do
      %{"needs_tools" => nt} when is_boolean(nt) -> nt
      _ -> true
    end
  end

  # ---- Stage 3: complexity (Ollama via Req) ----
  defp complexity(prompt, cfg) do
    stage = cfg[:complexity]
    timeout = cfg[:timeout_ms] || 30_000

    case ollama_json(stage, @complexity_prompt, prompt, timeout) do
      %{"label" => l} when l in ["SIMPLE", "MULTI_STEP", "NON_ACTIONABLE"] -> l
      _ -> "SIMPLE"
    end
  end

  # ---- Stage 4: intent (runtime-resolved gateway module) ----
  defp intent(prompt, _sensitivity, cfg) do
    mod = cfg[:intent_extractor]
    stage = cfg[:intent]

    if loaded?(mod, :extract, 2) do
      opts = [
        provider: stage[:provider],
        model: stage[:model],
        timeout: cfg[:timeout_ms] || 30_000
      ]

      case mod.extract(prompt, opts) do
        {:ok, intent} ->
          %{
            "goal" => intent[:goal] || intent.goal,
            "risk_level" => to_string(intent[:risk_level] || intent.risk_level)
          }

        _ ->
          nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  end

  # ---- Stage 6: retrieval (JIT tool injection) ----
  # Embedding recall against the action index → top-K modules → expand to the
  # action NAMES the tool system understands (dot-form, e.g. "file.read").
  # Returns a list of names, or [] if disabled / unavailable. Embedding-only for
  # now (fast, no hot-path LLM call); hybrid LLM rerank is a future enhancement.
  @doc false
  def retrieve_tool_names(prompt, cfg) do
    stage = cfg[:retrieval] || []

    if Keyword.get(stage, :enabled, false) do
      with path when is_binary(path) <- index_path(stage),
           {:ok, index} <- load_index(path),
           {:ok, qvec} <- embed_query(stage, prompt, cfg[:timeout_ms] || 30_000) do
        stage
        |> top_modules(index, qvec)
        |> expand_modules()
      else
        _ -> []
      end
    else
      []
    end
  rescue
    _ -> []
  end

  defp index_path(stage) do
    case stage[:index_path] do
      p when is_binary(p) -> p
      _ -> default_index_path()
    end
  end

  defp default_index_path do
    Path.join(
      :code.priv_dir(:arbor_orchestrator),
      "eval_datasets/preprocessor_tool_retrieval/action_index.json"
    )
  rescue
    _ -> nil
  end

  defp load_index(path) do
    key = {__MODULE__, :index, path}

    case :persistent_term.get(key, :miss) do
      :miss ->
        with {:ok, body} <- File.read(path),
             {:ok, index} <- Jason.decode(body) do
          :persistent_term.put(key, index)
          {:ok, index}
        else
          _ -> :error
        end

      index ->
        {:ok, index}
    end
  end

  defp embed_query(stage, prompt, timeout) do
    base = stage[:base_url] || "http://localhost:11434"
    model = stage[:embed_model] || "mxbai-embed-large"

    case Req.post(base <> "/api/embeddings",
           json: %{model: model, prompt: prompt},
           receive_timeout: timeout
         ) do
      {:ok, %{status: 200, body: %{"embedding" => v}}} when is_list(v) -> {:ok, v}
      _ -> :error
    end
  end

  defp top_modules(stage, index, qvec) do
    model = stage[:embed_model] || "mxbai-embed-large"
    top_k = stage[:top_k] || 5

    index["actions"]
    |> Enum.flat_map(fn a ->
      case a["embeddings"][model] do
        v when is_list(v) -> [{a["module"], cosine(qvec, v)}]
        _ -> []
      end
    end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(top_k)
    |> Enum.map(&elem(&1, 0))
  end

  defp cosine(a, b) when length(a) == length(b) do
    {dot, na, nb} =
      Enum.zip(a, b)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {x, y}, {d, ax, bx} ->
        {d + x * y, ax + x * x, bx + y * y}
      end)

    denom = :math.sqrt(na) * :math.sqrt(nb)
    if denom == 0.0, do: 0.0, else: dot / denom
  end

  defp cosine(_, _), do: 0.0

  # Map retrieved index modules (e.g. "Arbor.Actions.File") to the action names the
  # tool system uses (e.g. "file.read"). One module fans out to all action names
  # whose module is that module or a descendant ("Arbor.Actions.File.Read").
  @doc false
  def expand_modules(modules) do
    pairs = action_name_pairs()

    modules
    |> Enum.flat_map(fn m ->
      prefix = m <> "."
      for {mod_str, name} <- pairs, mod_str == m or String.starts_with?(mod_str, prefix), do: name
    end)
    |> Enum.uniq()
  end

  # Cached [{module_string, action_name}] from the runtime action registry.
  # Resolved at runtime (orchestrator doesn't compile-depend on arbor_actions).
  defp action_name_pairs do
    key = {__MODULE__, :action_name_pairs}

    case :persistent_term.get(key, :miss) do
      :miss ->
        case build_action_name_pairs() do
          # Don't cache an empty result. Arbor.Actions may simply not be loaded
          # yet (early startup, or running from an app that doesn't depend on it).
          # Caching [] here would fail-silent — retrieval would return no tools
          # for the entire VM lifetime even after the registry becomes available.
          [] ->
            []

          pairs ->
            :persistent_term.put(key, pairs)
            pairs
        end

      pairs ->
        pairs
    end
  end

  defp build_action_name_pairs do
    # Variable indirection + apply/3 keeps the (runtime-resolved) arbor_actions
    # module out of static analysis — orchestrator has no compile-time dep on it.
    mod = Arbor.Actions

    if loaded?(mod, :all_actions, 0) and loaded?(mod, :action_module_to_name, 1) do
      for m <- apply(mod, :all_actions, []) do
        {inspect(m), apply(mod, :action_module_to_name, [m])}
      end
    else
      []
    end
  rescue
    _ -> []
  end

  # ---- helpers ----
  defp chat(system, user),
    do: [%{role: "system", content: system}, %{role: "user", content: user}]

  defp ollama_json(stage, system, user, timeout) do
    url = (stage[:base_url] || "http://localhost:11434") <> "/api/chat"

    body = %{
      model: stage[:model],
      messages: chat(system, user),
      stream: false,
      format: "json",
      think: false,
      options: %{temperature: 0.0, num_ctx: 8192}
    }

    case Req.post(url, json: body, receive_timeout: timeout) do
      {:ok, %{status: 200, body: %{"message" => %{"content" => content}}}} ->
        case Jason.decode(content) do
          {:ok, parsed} -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp loaded?(mod, fun, arity) do
    is_atom(mod) and Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity)
  end

  defp safe(fun, default) do
    fun.()
  rescue
    e ->
      Logger.warning("[Preprocessor] stage failed open: #{Exception.message(e)}")
      default
  catch
    :exit, _ -> default
  end

  # Run a stage (fail-open) and emit its duration:
  # [:arbor, :preprocessor, :stage] with %{duration: native} and %{stage: name}.
  defp timed_stage(name, fun, default) do
    start = System.monotonic_time()
    result = safe(fun, default)

    :telemetry.execute(
      [:arbor, :preprocessor, :stage],
      %{duration: System.monotonic_time() - start},
      %{stage: name}
    )

    result
  end
end
