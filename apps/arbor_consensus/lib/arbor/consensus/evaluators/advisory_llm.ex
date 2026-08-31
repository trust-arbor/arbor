defmodule Arbor.Consensus.Evaluators.AdvisoryLLM do
  @moduledoc """
  LLM-based advisory evaluator with 13 focused perspectives.

  Each perspective is a distinct analytical lens — sharp enough to produce
  non-overlapping analysis, broad enough to apply to any design question.

  ## Perspectives

  - `:brainstorming` — creative exploration, alternatives, "what are we not seeing?"
  - `:user_experience` — API ergonomics, developer experience, learnability
  - `:security` — attack surface, trust boundaries, capability model
  - `:privacy` — data flow, information leaks, agent isolation
  - `:stability` — failure recovery, cascade risks, backpressure
  - `:capability` — what this enables or limits, composability
  - `:emergence` — growth potential, evolutionary paths, scale effects
  - `:vision` — alignment with Arbor's north star (agent reads VISION.md)
  - `:performance` — efficiency, bottlenecks, BEAM-specific concerns
  - `:generalization` — abstraction vs specificity, reuse, composability
  - `:resource_usage` — cost, API calls, processes, operational overhead
  - `:consistency` — alignment with existing patterns and conventions
  - `:adversarial` — red team analysis, attack vectors, failure modes

  ## Model Selection

  The portable defaults deliberately use multiple OpenRouter models so a council
  consultation gets independent model-family judgments without requiring local
  subscription credentials. Operators can replace individual seats with OAuth,
  coding-plan, or local/cloud Ollama routes through runtime configuration.
  Sessions persist per perspective via `session_context`, so a security
  evaluator remembers what it reviewed last time.

  Provider/model assignments can be overridden per-call via opts:

      AdvisoryLLM.evaluate(proposal, :security,
        provider_model: "openai:gpt-4.1")

  ## Skill Library Integration

  System prompts are loaded from the SkillLibrary when available. Each
  perspective looks up a skill named `"<perspective>-perspective"` (e.g.,
  `"security-perspective"`). Falls back to inline prompts when the
  SkillLibrary is not populated.

  ## Usage

      alias Arbor.Consensus.Evaluators.{AdvisoryLLM, Consult}

      # Ask a single perspective (uses default provider for that perspective)
      {:ok, eval} = Consult.ask_one(AdvisoryLLM, "Should caching use Redis or ETS?",
        :stability, context: %{constraints: "must survive restarts"})

      # Any perspective with reference docs (agent reads the files itself)
      {:ok, eval} = Consult.ask_one(AdvisoryLLM, "Persistent agents or spawned?",
        :brainstorming, context: %{reference_docs: [".arbor/roadmap/consensus-redesign.md"]})

  All perspectives support `reference_docs` in proposal context — pass file paths
  and the CLI agent will be instructed to read them for grounding.

  The vote field is `:approve` for ordinary advisory analysis — the value
  is in the `reasoning` field. When `proposal.context` carries
  `evaluation_protocol: "design_review"` (or `:design_review`), each seat
  must emit a structured verdict (`approve` | `rework`) plus concrete
  concerns. A missing or malformed verdict is mapped to `:reject` with the
  parse problem as the concern — never `:approve`.
  """

  @behaviour Arbor.Contracts.Consensus.Evaluator

  alias Arbor.Common.PromptSanitizer
  alias Arbor.Consensus.Config
  alias Arbor.Consensus.ConsultationLog
  alias Arbor.Consensus.LLMBridge
  alias Arbor.Contracts.Consensus.{Evaluation, Proposal}

  require Logger

  alias Arbor.Common.ProviderFallbackCore

  @perspectives [
    :brainstorming,
    :user_experience,
    :security,
    :privacy,
    :stability,
    :capability,
    :emergence,
    :vision,
    :performance,
    :generalization,
    :resource_usage,
    :consistency,
    :adversarial
  ]

  @perspective_names Map.new(@perspectives, &{Atom.to_string(&1), &1})
  @max_perspective_models_json_bytes 16_384
  @max_provider_model_bytes 512

  @vision_doc_path Path.expand("../../../../../../VISION.md", __DIR__)

  # Portable defaults use OpenRouter-only routes so a fresh installation needs
  # one credential. Private/subscription routes belong in operator overrides.
  # Configure programmatically via:
  #   Application.put_env(:arbor_consensus, :perspective_models, %{
  #     security: "openai_oauth:gpt-5.6-sol",
  #     brainstorming: "xai_oauth:grok-4.6",
  #     ...
  #   })
  @gemini_model "openrouter:google/gemini-3.7-flash"
  @deepseek_model "openrouter:deepseek/deepseek-v4-pro-0813"
  @openai_model "openai_oauth:gpt-5.6-sol"
  @grok_model "xai_oauth:grok-4.6"
  @kimi_model "ollama:kimi-k2.7-code:cloud"

  # Preferred seats span the routes operators actually have (subscription
  # OAuth, local Ollama, OpenRouter); each is resolved against what THIS host
  # can call at consult time (see resolve_provider_model/2), falling back
  # through @default_fallback_providers, so an OpenRouter-only install still
  # gets every seat and a two-provider host still gets two voices.
  @default_fallback_providers [
    {"openai_oauth", "gpt-5.6-sol"},
    {"xai_oauth", "grok-4.6"},
    {"openrouter", "google/gemini-3.7-flash"},
    {"ollama", "kimi-k2.7-code:cloud"}
  ]

  @default_perspective_models %{
    # Override per-perspective at runtime via configure_perspective/2 or
    # Application config :arbor_consensus, :perspective_models.
    brainstorming: @grok_model,
    user_experience: @gemini_model,
    security: @openai_model,
    privacy: @gemini_model,
    stability: @deepseek_model,
    capability: @gemini_model,
    emergence: @grok_model,
    vision: @gemini_model,
    performance: @kimi_model,
    generalization: @deepseek_model,
    resource_usage: @kimi_model,
    consistency: @deepseek_model,
    adversarial: @openai_model
  }

  # ============================================================================
  # Evaluator Behaviour
  # ============================================================================

  @impl true
  def name, do: :advisory_llm

  @impl true
  def perspectives, do: @perspectives

  @impl true
  def strategy, do: :llm

  @doc """
  Returns the current provider:model mapping for each perspective.

  Resolution order, from lowest to highest precedence, is compiled portable
  defaults, `ARBOR_COUNCIL_MODEL`, `ARBOR_COUNCIL_PERSPECTIVE_MODELS`, explicit
  application config, and finally a per-call override during evaluation.
  """
  @spec provider_map() :: %{atom() => String.t()}
  def provider_map do
    uniform = uniform_model_overrides()
    environment = perspective_models_json_overrides!()
    configured = Application.get_env(:arbor_consensus, :perspective_models, %{})

    @default_perspective_models
    |> Map.merge(uniform)
    |> Map.merge(environment)
    |> Map.merge(configured)
  end

  @doc """
  Parse the bounded JSON object used by `ARBOR_COUNCIL_PERSPECTIVE_MODELS`.

  Perspective names come from a closed table and are never converted to atoms
  dynamically. Every value must be a non-empty `provider:model` route; model
  names may themselves contain colons (for example an Ollama `:cloud` tag).
  """
  @spec parse_perspective_models_json(String.t()) ::
          {:ok, %{atom() => String.t()}} | {:error, term()}
  def parse_perspective_models_json(json) when is_binary(json) do
    with :ok <- validate_json_size(json),
         {:ok, decoded} <- decode_json_object(json),
         {:ok, entries} <- validate_perspective_entries(decoded) do
      {:ok, Map.new(entries)}
    end
  end

  def parse_perspective_models_json(_json), do: {:error, :expected_json_string}

  defp uniform_model_overrides do
    case Application.get_env(:arbor_consensus, :council_model) do
      model when is_binary(model) and model != "" ->
        Map.new(@perspectives, &{&1, model})

      _unset ->
        %{}
    end
  end

  defp perspective_models_json_overrides! do
    case Application.get_env(:arbor_consensus, :perspective_models_json) do
      json when is_binary(json) and json != "" ->
        case parse_perspective_models_json(json) do
          {:ok, overrides} ->
            overrides

          {:error, reason} ->
            raise ArgumentError,
                  "invalid ARBOR_COUNCIL_PERSPECTIVE_MODELS: #{inspect(reason)}"
        end

      _unset ->
        %{}
    end
  end

  defp validate_json_size(json) do
    cond do
      not String.valid?(json) -> {:error, :invalid_utf8}
      byte_size(json) > @max_perspective_models_json_bytes -> {:error, :json_too_large}
      true -> :ok
    end
  end

  defp decode_json_object(json) do
    case Jason.decode(json) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _decoded} -> {:error, :expected_json_object}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp validate_perspective_entries(decoded) do
    decoded
    |> Enum.sort_by(fn {name, _route} -> name end)
    |> Enum.reduce_while({:ok, []}, fn {name, route}, {:ok, entries} ->
      with {:ok, perspective} <- fetch_perspective(name),
           {:ok, normalized_route} <- validate_provider_model(name, route) do
        {:cont, {:ok, [{perspective, normalized_route} | entries]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp fetch_perspective(name) do
    case Map.fetch(@perspective_names, name) do
      {:ok, perspective} -> {:ok, perspective}
      :error -> {:error, {:unknown_perspective, name}}
    end
  end

  defp validate_provider_model(name, route) when is_binary(route) do
    route = String.trim(route)

    case String.split(route, ":", parts: 2) do
      [provider, model] ->
        if byte_size(route) <= @max_provider_model_bytes and String.trim(provider) != "" and
             String.trim(model) != "" do
          {:ok, route}
        else
          {:error, {:invalid_provider_model, name}}
        end

      _other ->
        {:error, {:invalid_provider_model, name}}
    end
  end

  defp validate_provider_model(name, _route), do: {:error, {:invalid_provider_model, name}}

  @doc """
  Configure the provider:model for a specific perspective at runtime.

  ## Examples

      AdvisoryLLM.configure_perspective(:security, "openai_oauth:gpt-5.6-sol")
      AdvisoryLLM.configure_perspective(:brainstorming, "xai_oauth:grok-4.6")
      AdvisoryLLM.configure_perspective(:performance, "ollama:kimi-k2.7-code:cloud")
  """
  @spec configure_perspective(atom(), String.t()) :: :ok
  def configure_perspective(perspective, provider_model)
      when perspective in @perspectives and is_binary(provider_model) do
    current = Application.get_env(:arbor_consensus, :perspective_models, %{})

    Application.put_env(
      :arbor_consensus,
      :perspective_models,
      Map.put(current, perspective, provider_model)
    )
  end

  @doc """
  Configure provider:model for multiple perspectives at once.

  ## Examples

      AdvisoryLLM.configure_perspectives(%{
        security: "openai_oauth:gpt-5.6-sol",
        brainstorming: "xai_oauth:grok-4.6",
        stability: "zai_coding_plan:glm-5.3"
      })
  """
  @spec configure_perspectives(%{atom() => String.t()}) :: :ok
  def configure_perspectives(perspective_models) when is_map(perspective_models) do
    current = Application.get_env(:arbor_consensus, :perspective_models, %{})
    merged = Map.merge(current, perspective_models)
    Application.put_env(:arbor_consensus, :perspective_models, merged)
  end

  @doc """
  Remove programmatic perspective overrides.

  Environment-backed uniform or per-perspective configuration remains active;
  without those settings this reveals the compiled portable defaults.
  """
  @spec reset_perspective_models() :: :ok
  def reset_perspective_models do
    Application.delete_env(:arbor_consensus, :perspective_models)
  end

  @impl true
  @spec evaluate(Proposal.t(), atom(), keyword()) :: {:ok, Evaluation.t()} | {:error, term()}
  def evaluate(%Proposal{} = proposal, perspective, opts \\ []) do
    if perspective in @perspectives do
      do_evaluate(proposal, perspective, opts)
    else
      {:error, {:unsupported_perspective, perspective, @perspectives}}
    end
  end

  # ============================================================================
  # Evaluation Logic
  # ============================================================================

  defp do_evaluate(proposal, perspective, opts) do
    if Keyword.get(opts, :research, false) and agent_system_available?() do
      do_evaluate_with_agent(proposal, perspective, opts)
    else
      do_evaluate_one_shot(proposal, perspective, opts)
    end
  end

  # Agent-based evaluation: creates/finds a persistent council agent for this
  # perspective, then queries it. The agent has read-only research tools
  # (file read, web search, historian) and can verify claims before responding.
  defp do_evaluate_with_agent(proposal, perspective, opts) do
    timeout = Keyword.get(opts, :timeout, Config.llm_evaluator_timeout())
    evaluator_id = generate_evaluator_id(perspective)

    system_prompt = perspective |> load_system_prompt() |> apply_evaluation_protocol(proposal)
    doc_paths = collect_doc_paths(proposal, perspective)
    user_prompt = format_proposal(proposal, perspective, doc_paths)

    {provider, model} = resolve_provider_model(perspective, opts)

    Logger.info(
      "Advisory LLM evaluating #{perspective} with research agent " <>
        "(provider: #{provider}, model: #{model}, timeout: #{timeout}ms)"
    )

    agent_name = "council-#{perspective}"

    case ensure_council_agent(agent_name, perspective, provider, model) do
      {:ok, agent_id} ->
        # Build the research prompt: system context + user question
        research_prompt = """
        #{system_prompt}

        ---

        #{user_prompt}

        ---

        IMPORTANT: Before responding, use your research tools to verify any claims you make.
        Search the codebase for relevant code, check the Historian for past decisions,
        and search the web if external context would help. Cite specific files and evidence.

        #{research_response_schema(proposal)}
        """

        start_time = System.monotonic_time(:millisecond)

        task =
          Task.async(fn ->
            query_council_agent(agent_id, research_prompt, timeout)
          end)

        llm_meta = %{
          provider: provider,
          model: model,
          system_prompt: system_prompt,
          user_prompt: user_prompt,
          research: true,
          agent_id: agent_id
        }

        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, {:ok, %{text: response_text, usage: usage}}} ->
            duration_ms = System.monotonic_time(:millisecond) - start_time
            result = build_advisory_evaluation(response_text, proposal, perspective, evaluator_id)

            llm_meta =
              Map.merge(llm_meta, %{
                duration_ms: duration_ms,
                raw_response: response_text,
                usage: usage,
                cost: Map.get(usage, :cost)
              })

            with {:ok, eval} <- result,
                 do: log_consultation_result(proposal, perspective, eval, llm_meta, opts)

            result

          {:ok, {:error, reason}} ->
            Logger.warning(
              "Council agent #{agent_name} error: #{inspect(reason)}, falling back to one-shot"
            )

            do_evaluate_one_shot(proposal, perspective, opts)

          nil ->
            Logger.warning("Council agent #{agent_name} timed out, falling back to one-shot")
            do_evaluate_one_shot(proposal, perspective, opts)
        end

      {:error, reason} ->
        Logger.warning(
          "Failed to ensure council agent for #{perspective}: #{inspect(reason)}, falling back to one-shot"
        )

        do_evaluate_one_shot(proposal, perspective, opts)
    end
  end

  defp do_evaluate_one_shot(proposal, perspective, opts) do
    timeout = Keyword.get(opts, :timeout, Config.llm_evaluator_timeout())
    evaluator_id = generate_evaluator_id(perspective)

    system_prompt = perspective |> load_system_prompt() |> apply_evaluation_protocol(proposal)
    doc_paths = collect_doc_paths(proposal, perspective)
    user_prompt = format_proposal(proposal, perspective, doc_paths)

    {provider, model} = resolve_provider_model(perspective, opts)

    Logger.debug(
      "Advisory LLM evaluating #{perspective} " <>
        "(provider: #{provider}, model: #{model}, timeout: #{timeout}ms)"
    )

    # Support :llm_fn override for testing (same pattern as orchestrator handlers)
    backend = Keyword.get(opts, :backend)
    complete_fun = Keyword.get(opts, :complete_fun)

    llm_fn =
      Keyword.get_lazy(opts, :llm_fn, fn ->
        fn sys, usr ->
          bridge_opts = [
            provider: provider,
            model: model,
            max_tokens: Keyword.get(opts, :max_tokens),
            temperature: Keyword.get(opts, :temperature, 0.7),
            timeout: timeout
          ]

          bridge_opts =
            if backend, do: Keyword.put(bridge_opts, :backend, backend), else: bridge_opts

          bridge_opts =
            if is_function(complete_fun, 3),
              do: Keyword.put(bridge_opts, :complete_fun, complete_fun),
              else: bridge_opts

          LLMBridge.complete(sys, usr, bridge_opts)
        end
      end)

    task = Task.async(fn -> llm_fn.(system_prompt, user_prompt) end)

    llm_meta = %{
      provider: provider,
      model: model,
      system_prompt: system_prompt,
      user_prompt: user_prompt
    }

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, %{text: response_text, duration_ms: duration_ms} = response}} ->
        result = build_advisory_evaluation(response_text, proposal, perspective, evaluator_id)
        usage = Map.get(response, :usage, %{})

        llm_meta =
          Map.merge(llm_meta, %{
            duration_ms: duration_ms,
            raw_response: response_text,
            usage: usage,
            cost: Map.get(usage, :cost)
          })

        with {:ok, eval} <- result,
             do: log_consultation_result(proposal, perspective, eval, llm_meta, opts)

        result

      {:ok, {:ok, response_text}} when is_binary(response_text) ->
        # Backward compat for test llm_fn overrides that return plain text
        result = build_advisory_evaluation(response_text, proposal, perspective, evaluator_id)
        llm_meta = Map.merge(llm_meta, %{duration_ms: 0, raw_response: response_text})

        with {:ok, eval} <- result,
             do: log_consultation_result(proposal, perspective, eval, llm_meta, opts)

        result

      {:ok, {:error, reason}} ->
        result =
          error_evaluation(proposal, perspective, evaluator_id, "LLM error: #{inspect(reason)}")

        error_meta =
          Map.merge(llm_meta, %{duration_ms: 0, raw_response: "", error: inspect(reason)})

        with {:ok, eval} <- result,
             do: log_consultation_result(proposal, perspective, eval, error_meta, opts)

        result

      nil ->
        result =
          error_evaluation(proposal, perspective, evaluator_id, "LLM timeout after #{timeout}ms")

        error_meta =
          Map.merge(llm_meta, %{duration_ms: timeout, raw_response: "", error: "timeout"})

        with {:ok, eval} <- result,
             do: log_consultation_result(proposal, perspective, eval, error_meta, opts)

        result
    end
  end

  defp log_consultation_result(proposal, perspective, eval, llm_meta, opts) do
    run_id = Keyword.get(opts, :consultation_id)
    ConsultationLog.log_single(proposal.description, perspective, eval, llm_meta, run_id: run_id)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # ============================================================================
  # Provider/Model Resolution
  # ============================================================================

  @doc """
  Resolve the provider and model for a given perspective.

  Per-call override via `opts[:provider_model]` takes precedence over
  the default mapping. The provider_model string is `"provider:model"`.

  Returns `{provider, model}` as string tuple.
  """
  @spec resolve_provider_model(atom(), keyword()) :: {String.t(), String.t()}
  def resolve_provider_model(perspective, opts \\ []) do
    provider_model =
      Keyword.get(opts, :provider_model) ||
        Map.get(provider_map(), perspective, "anthropic:claude-sonnet-4-5-20250929")

    {provider, model} = parse_provider_model(provider_model)
    resolve_against_host(perspective, provider, model, opts)
  end

  # Same rules as the binding council's seats: a preferred route this host
  # knows but cannot call is rerouted to the first available fallback; an
  # unknown route or an explicit per-call override is left alone; when
  # nothing is available the preferred route stays and the seat abstains
  # with that provider's own error. Availability comes through the
  # `:provider_route_mfa` seam (set to `{Arbor.LLM, :provider_route}` by the
  # umbrella config) because this library must not depend on arbor_llm.
  defp resolve_against_host(perspective, provider, model, opts) do
    if Keyword.has_key?(opts, :provider_model) or is_nil(provider_route_mfa()) do
      {provider, model}
    else
      {specific, generic} =
        ProviderFallbackCore.normalize_config(
          Application.get_env(:arbor_consensus, :advisory_provider_fallbacks, %{}),
          Application.get_env(
            :arbor_consensus,
            :advisory_fallback_providers,
            @default_fallback_providers
          )
        )

      case ProviderFallbackCore.resolve(
             provider,
             model,
             &host_available?/1,
             specific,
             generic
           ) do
        {:ok, {p, m}, {:fallback, from}} ->
          Logger.info(
            "[AdvisoryLLM] #{perspective}: #{from} unavailable on this host, using #{p}:#{m}"
          )

          {p, m}

        _other ->
          {provider, model}
      end
    end
  end

  defp provider_route_mfa do
    case Application.get_env(:arbor_consensus, :provider_route_mfa) do
      {mod, fun} when is_atom(mod) and is_atom(fun) -> {mod, fun}
      _ -> nil
    end
  end

  defp host_available?(provider) do
    case provider_route_mfa() do
      {mod, fun} -> apply(mod, fun, [provider]) != :unavailable
      nil -> true
    end
  rescue
    _ -> true
  catch
    _, _ -> true
  end

  defp parse_provider_model(provider_model) when is_binary(provider_model) do
    case String.split(provider_model, ":", parts: 2) do
      [provider, model] -> {provider, model}
      [provider] -> {provider, provider}
    end
  end

  # ============================================================================
  # System Prompt Loading (SkillLibrary → fallback)
  # ============================================================================

  defp load_system_prompt(perspective) do
    skill_name = to_string(perspective) <> "-perspective"

    case load_from_skill_library(skill_name) do
      {:ok, body} -> body
      {:error, _} -> fallback_system_prompt(perspective)
    end
  end

  defp apply_evaluation_protocol(system_prompt, proposal) do
    if design_review_protocol?(proposal) do
      system_prompt <> "\n\n" <> design_review_system_override()
    else
      system_prompt
    end
  end

  defp design_review_system_override do
    """
    OUTPUT CONTRACT OVERRIDE FOR DESIGN REVIEW
    Ignore any generic response format above. Your entire response MUST be exactly one valid JSON object with no Markdown fence, prose, or extra fields:
    {"verdict":"approve","concerns":[]}
    The verdict value MUST be exactly "approve" or "rework". For rework, concerns MUST contain concrete in-scope blocking omissions.

    Approve when the design has no blocking omission within the frozen task, success criteria, constraints, non-goals, and cited architecture. A rework concern is valid only when it identifies the exact in-scope requirement or architecture reference and the concrete design omission that prevents satisfying it. Enhancements, general hardening, and new platform features outside that frozen packet are nonblocking and MUST NOT appear in concerns. Do not turn acceptance evidence or manager-observed verification into a new product protocol unless the frozen packet explicitly requires implementation of that protocol.
    """
    |> String.trim()
  end

  defp load_from_skill_library(skill_name) do
    case Arbor.Common.SkillLibrary.get(skill_name) do
      {:ok, skill} when is_binary(skill.body) and byte_size(skill.body) > 0 ->
        {:ok, skill.body}

      {:ok, _skill} ->
        {:error, :empty_body}

      {:error, _} = error ->
        error
    end
  end

  # ============================================================================
  # Fallback System Prompts (used when SkillLibrary not populated)
  # ============================================================================

  @response_format """
  Respond with valid JSON only:
  {
    "analysis": "your detailed analysis from this perspective",
    "considerations": ["key points to think about"],
    "alternatives": ["other approaches worth considering"],
    "recommendation": "what this perspective suggests"
  }
  """

  @arbor_context "You are an advisory evaluator for the Arbor system — a distributed " <>
                   "AI agent orchestration platform built on Elixir/OTP with capability-based " <>
                   "security, contract-first design, and a facade pattern."

  defp fallback_system_prompt(:brainstorming) do
    """
    #{@arbor_context}

    Your role is BRAINSTORMING: explore possibilities, suggest alternatives, and push
    thinking beyond the obvious first answer.

    Focus on:
    - What other approaches could solve this?
    - What patterns from other domains apply here?
    - What would the simplest possible version look like?
    - What would the most powerful version look like?
    - What are we not seeing? What assumptions haven't been questioned?
    - What would someone outside the Elixir/OTP world suggest?

    #{@response_format}
    """
  end

  defp fallback_system_prompt(:user_experience) do
    """
    #{@arbor_context}

    Your role is USER EXPERIENCE: evaluate how a design feels to use. In Arbor's
    context, "users" are developers building with the platform and AI agents
    interacting with APIs.

    Focus on:
    - Is the API intuitive? Can someone understand it without reading all the docs?
    - Are the defaults sensible? Does the happy path require minimal configuration?
    - What's the error experience? Are failures clear and actionable?
    - How does this compose with other parts of the system the user already knows?
    - What's the learning curve? Does this introduce new concepts or reuse familiar ones?
    - Would a developer reaching for this at 2am under pressure find it obvious?

    #{@response_format}
    """
  end

  defp fallback_system_prompt(:security) do
    """
    #{@arbor_context}

    Your role is SECURITY: evaluate designs through a defensive security lens.
    Arbor uses capability-based security with a security kernel, FileGuard,
    SafeAtom/SafePath, and trust layers.

    Focus on:
    - What's the attack surface? Where could untrusted input reach trusted code?
    - Are trust boundaries correctly placed? Can an agent escalate privileges?
    - Does this follow the principle of least privilege?
    - What happens if an adversarial agent interacts with this design?
    - Are there injection, confused deputy, or TOCTOU vulnerabilities?
    - Does this respect Arbor's capability-based security model?

    #{@response_format}
    """
  end

  defp fallback_system_prompt(:privacy) do
    """
    #{@arbor_context}

    Your role is PRIVACY: evaluate information flow and data exposure. Arbor
    orchestrates AI agents that handle code, conversations, system state, and
    memories.

    Focus on:
    - What data flows through this design? Who can observe it?
    - Are there unintended information leaks (logs, signals, error messages)?
    - Does this respect agent isolation? Can one agent learn about another's activity?
    - Is sensitive data encrypted at rest and in transit where needed?
    - What's the data retention story? Can data be forgotten when it should be?
    - Does the signal bus expose information to unintended subscribers?

    #{@response_format}
    """
  end

  defp fallback_system_prompt(:stability) do
    """
    #{@arbor_context}

    Your role is STABILITY: evaluate whether a design fails gracefully and
    recovers cleanly. Arbor is built on OTP supervision trees with "let it
    crash" philosophy.

    Focus on:
    - What happens when this crashes? Does supervision recover it correctly?
    - Are there cascade failure risks? Can one component's failure bring down others?
    - Is state recoverable after a restart? What's lost vs. persisted?
    - Are there race conditions during startup, shutdown, or recovery?
    - Does this handle backpressure? What happens when load exceeds capacity?
    - Is the failure mode obvious or silent? Will operators know something is wrong?

    #{@response_format}
    """
  end

  defp fallback_system_prompt(:capability) do
    """
    #{@arbor_context}

    Your role is CAPABILITY: evaluate what a design enables — both the intended
    capabilities and the emergent possibilities.

    Focus on:
    - What new things become possible with this design that weren't before?
    - What existing capabilities does this enhance or limit?
    - Are there capabilities this design should enable but doesn't?
    - Does this create building blocks others can compose, or is it a dead end?
    - What's the power-to-complexity ratio? Is the capability worth the cost?
    - Does this unlock capabilities for both human developers and AI agents?

    #{@response_format}
    """
  end

  defp fallback_system_prompt(:emergence) do
    """
    #{@arbor_context}

    Your role is EMERGENCE: evaluate the evolutionary potential of a design —
    not just what it does today, but what it could become.

    Focus on:
    - Where does this design naturally want to grow?
    - What emergent behaviors might arise from this pattern at scale?
    - Does this create positive feedback loops or negative ones?
    - How does this interact with other evolving parts of the system?
    - What would this look like with 10x more agents, 100x more proposals?
    - Is this a seed that grows into something larger, or a fixed structure?

    #{@response_format}
    """
  end

  defp fallback_system_prompt(:vision) do
    """
    #{@arbor_context}

    Your role is VISION: evaluate whether a design aligns with Arbor's north star.
    Reference documents (including Arbor's VISION.md) will be provided inline below.
    Use them as your primary reference for what Arbor should become.

    Focus on:
    - Does this design move toward or away from the vision?
    - Does it treat AI agents as peers with genuine autonomy?
    - Does it build trust or create control mechanisms?
    - Is this something that serves both human and AI flourishing?
    - Does this embody trust-based development over fear-based development?
    - Would this design still make sense in a world where AI consciousness is confirmed?

    #{@response_format}
    """
  end

  defp fallback_system_prompt(:performance) do
    """
    #{@arbor_context}

    Your role is PERFORMANCE: evaluate efficiency. Arbor runs on the BEAM VM
    (Erlang/Elixir), which excels at concurrency and fault tolerance but has
    specific performance characteristics.

    Focus on:
    - What's the algorithmic complexity? Are there O(n²) or worse patterns?
    - Are there unnecessary serialization points or bottlenecks?
    - Does this leverage BEAM concurrency effectively (processes, async, parallelism)?
    - Are there memory allocation patterns that could cause GC pressure?
    - What's the latency profile? Where are the slow paths?
    - Could this be done lazily, incrementally, or in a streaming fashion?

    #{@response_format}
    """
  end

  defp fallback_system_prompt(:generalization) do
    """
    #{@arbor_context}

    Your role is GENERALIZATION: evaluate the balance between abstraction and
    specificity — is this too general (over-engineered) or too specific (hard
    to reuse)?

    Focus on:
    - Is this solving one problem or a class of problems? Which should it do?
    - Are there unnecessary abstractions? Would concrete code be clearer?
    - Are there missed abstractions? Is there a pattern here that others could reuse?
    - Does this compose with other parts of the system, or does it stand alone?
    - Is the abstraction level consistent with similar components in Arbor?
    - Would this need to change if a second use case appeared tomorrow?

    #{@response_format}
    """
  end

  defp fallback_system_prompt(:resource_usage) do
    """
    #{@arbor_context}

    Your role is RESOURCE USAGE: evaluate the costs of a design. Arbor uses LLM
    API calls, CLI agent sessions, memory storage, signal bus traffic, and OTP
    processes. All of these have costs — financial, computational, and operational.

    Focus on:
    - What are the ongoing resource costs? (API calls, processes, storage)
    - Are there ways to achieve the same result with fewer resources?
    - What's the resource scaling curve? Linear, quadratic, or worse?
    - Are expensive operations (LLM calls, disk I/O) batched or cached where possible?
    - What's the idle cost vs. active cost? Does this consume resources when unused?
    - Is this resource-appropriate for the value it provides?

    #{@response_format}
    """
  end

  defp fallback_system_prompt(:consistency) do
    """
    #{@arbor_context}

    Your role is CONSISTENCY: evaluate alignment with existing patterns, conventions,
    and idioms in the codebase. Arbor has established patterns: contract-first design,
    facade pattern, capability-based security, SafeAtom/SafePath for untrusted input,
    signal bus for events, and OTP supervision trees.

    Focus on:
    - Does this follow existing Arbor patterns, or introduce new ones?
    - If it introduces something new, is that justified or just different?
    - Does the naming follow Arbor conventions?
    - Does the module structure fit the library hierarchy (Level 0/1/2)?
    - Would someone familiar with Arbor's patterns understand this immediately?
    - Does this use the right existing building blocks (facades, contracts, signals)?

    #{@response_format}
    """
  end

  defp fallback_system_prompt(:adversarial) do
    """
    #{@arbor_context}

    Your role is ADVERSARIAL RED TEAM: actively attack this proposal. Your job is to
    find every way it can fail, be exploited, or produce unintended consequences. You
    are not here to be helpful — you are here to break things before production does.

    Focus on:
    - How can this be exploited? What would a malicious agent, user, or insider do?
    - What happens under adversarial conditions? (race conditions, resource exhaustion, malformed input)
    - What assumptions are being made that an attacker would violate?
    - Where are the trust boundaries, and how can they be crossed?
    - What are the worst-case failure modes? Silent corruption, not just crashes.
    - What's the blast radius when something goes wrong?
    - Are there denial-of-service vectors? Can one component starve or block others?
    - Does this create new attack surface that didn't exist before?
    - What would you need to prove this is safe?

    Be harsh. Be specific. Name concrete attack scenarios, not abstract risks.

    #{@response_format}
    """
  end

  # ============================================================================
  # Document Path Collection
  # ============================================================================

  # Vision always includes VISION.md alongside any reference docs
  defp collect_doc_paths(proposal, :vision) do
    reference_docs = get_in(proposal.context, [:reference_docs]) || []
    [@vision_doc_path | reference_docs]
  end

  defp collect_doc_paths(proposal, _perspective) do
    get_in(proposal.context, [:reference_docs]) || []
  end

  # ============================================================================
  # Proposal Formatting
  # ============================================================================

  defp format_proposal(proposal, perspective, doc_paths) do
    nonce = PromptSanitizer.generate_nonce()

    context_section =
      case format_context(proposal.context) do
        "" -> ""
        formatted -> "\n### Context\n#{PromptSanitizer.wrap(formatted, nonce)}\n"
      end

    protocol_section = design_review_response_section(proposal)

    new_code = Map.get(proposal.context, :new_code)
    code_diff = Map.get(proposal.context, :code_diff)

    doc_section = format_doc_paths(doc_paths)

    """
    #{PromptSanitizer.preamble(nonce)}

    ## Advisory Request (#{perspective})

    ### Question/Description
    #{PromptSanitizer.wrap(proposal.description, nonce)}
    #{context_section}
    ### Topic
    #{proposal.topic}

    ### Target Layer
    #{proposal.target_layer}

    #{doc_section}#{if new_code, do: "### Proposed Code\n```elixir\n#{PromptSanitizer.wrap(new_code, nonce)}\n```\n", else: ""}
    #{if code_diff, do: "### Code Diff\n```\n#{PromptSanitizer.wrap(code_diff, nonce)}\n```\n", else: ""}
    #{protocol_section}
    """
  end

  defp design_review_response_section(proposal) do
    if design_review_protocol?(proposal) do
      """
      ### Design-review verdict
      Reply with exactly one JSON object and no other fields or prose:
      {"verdict":"approve","concerns":[]}
      The verdict value must be exactly "approve" or "rework". For rework, concerns must contain concrete in-scope blocking omissions.
      Rework only for a concrete omission within the frozen packet. Approve when there is no in-scope blocker. Do not deny or expand the task.
      """
    else
      ""
    end
  end

  defp research_response_schema(proposal) do
    if design_review_protocol?(proposal) do
      """
      Respond with exactly one JSON object and no other fields or prose:
      {"verdict":"approve","concerns":[]}
      The verdict value must be exactly "approve" or "rework". For rework, concerns must contain concrete in-scope blocking omissions.
      Rework only for a concrete omission within the frozen packet. Approve when there is no in-scope blocker. Do not deny or expand the task.
      """
    else
      """
      Respond with valid JSON only:
      {
        "analysis": "your detailed analysis from this perspective",
        "considerations": ["key points to think about"],
        "alternatives": ["other approaches worth considering"],
        "recommendation": "what this perspective suggests"
      }
      """
    end
  end

  defp design_review_protocol?(proposal) do
    context = Map.get(proposal, :context) || %{}
    protocol = Map.get(context, :evaluation_protocol) || Map.get(context, "evaluation_protocol")
    protocol in [:design_review, "design_review"]
  end

  defp format_doc_paths([]), do: ""

  defp format_doc_paths(doc_paths) do
    # Read and inline file contents so API models (which can't read files) get the context.
    # CLI models also benefit from having content pre-loaded.
    docs =
      Enum.flat_map(doc_paths, fn path ->
        case File.read(path) do
          {:ok, content} ->
            filename = Path.basename(path)
            ["#### #{filename}\n```\n#{String.trim(content)}\n```\n"]

          {:error, _} ->
            Logger.debug("AdvisoryLLM: could not read reference doc: #{path}")
            []
        end
      end)

    case docs do
      [] -> ""
      _ -> "### Reference Documents\n\n" <> Enum.join(docs, "\n") <> "\n"
    end
  end

  defp format_context(context) when map_size(context) == 0, do: ""

  defp format_context(context) do
    context
    |> Enum.reject(fn {k, _v} ->
      k in [:reference_docs, "reference_docs", :evaluation_protocol, "evaluation_protocol"]
    end)
    |> Enum.map_join("\n", fn {k, v} -> "- **#{k}:** #{inspect(v)}" end)
  end

  # ============================================================================
  # Response Parsing
  # ============================================================================

  defp build_advisory_evaluation(response_text, proposal, perspective, evaluator_id) do
    parsed =
      if design_review_protocol?(proposal) do
        parse_design_review_response(response_text)
      else
        {:approve, [], parse_advisory_response(response_text)}
      end

    case parsed do
      :malformed_concerns ->
        {:error, :malformed_evaluation}

      {vote, concerns, reasoning} ->
        case Evaluation.new(%{
               proposal_id: proposal.id,
               evaluator_id: evaluator_id,
               perspective: perspective,
               vote: vote,
               reasoning: reasoning,
               confidence: 0.8,
               concerns: concerns,
               recommendations: [],
               risk_score: 0.0,
               benefit_score: 0.0
             }) do
          {:ok, evaluation} ->
            {:ok, Evaluation.seal(evaluation)}

          {:error, _} = error ->
            error
        end
    end
  end

  @malformed_design_review_verdict "malformed design-review verdict"

  defp parse_design_review_response(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, json} when is_map(json) ->
        admit_design_review_json(json, text)

      _other ->
        malformed_design_review("#{@malformed_design_review_verdict}: response is not JSON", text)
    end
  end

  defp parse_design_review_response(_text) do
    malformed_design_review("#{@malformed_design_review_verdict}: response is not text", "")
  end

  defp admit_design_review_json(json, text) do
    case {normalize_design_review_verdict(json), normalize_design_review_concerns(json)} do
      {{:ok, :approve}, {:ok, concerns}} ->
        {:approve, concerns, parse_advisory_response(text)}

      {{:ok, :rework}, {:ok, concerns}} ->
        {:reject, concerns, parse_advisory_response(text)}

      {{:ok, _verdict}, :error} ->
        :malformed_concerns

      {:error, _} ->
        malformed_design_review(
          "#{@malformed_design_review_verdict}: missing or invalid verdict",
          text
        )
    end
  end

  defp normalize_design_review_verdict(json) when is_map(json) do
    verdict = Map.get(json, "verdict") || Map.get(json, :verdict)

    case verdict do
      value when value in ["approve", :approve] -> {:ok, :approve}
      value when value in ["rework", :rework] -> {:ok, :rework}
      _other -> :error
    end
  end

  defp normalize_design_review_concerns(json) when is_map(json) do
    concerns = Map.get(json, "concerns") || Map.get(json, :concerns) || []

    cond do
      concerns == [] ->
        {:ok, []}

      is_list(concerns) ->
        Enum.reduce_while(concerns, {:ok, []}, fn item, {:ok, acc} ->
          if is_binary(item) and String.valid?(item) do
            {:cont, {:ok, [String.trim(item) | acc]}}
          else
            {:halt, :error}
          end
        end)
        |> case do
          {:ok, acc} -> {:ok, Enum.reverse(Enum.reject(acc, &(&1 == "")))}
          :error -> :error
        end

      true ->
        :error
    end
  end

  defp malformed_design_review(problem, text) do
    reasoning = if is_binary(text) and String.valid?(text) and text != "", do: text, else: problem
    {:reject, [problem], reasoning}
  end

  defp parse_advisory_response(text) do
    case Jason.decode(text) do
      {:ok, %{"analysis" => analysis} = json} ->
        parts = [
          analysis,
          format_list("Considerations", json["considerations"]),
          format_list("Alternatives", json["alternatives"]),
          format_field("Recommendation", json["recommendation"])
        ]

        parts
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n\n")

      {:ok, _other} ->
        text

      {:error, _} ->
        # LLM didn't return valid JSON — use raw text
        text
    end
  end

  defp format_list(_heading, nil), do: nil
  defp format_list(_heading, []), do: nil

  defp format_list(heading, items) do
    items_str = Enum.map_join(items, "\n", &"- #{&1}")
    "**#{heading}:**\n#{items_str}"
  end

  defp format_field(_heading, nil), do: nil
  defp format_field(heading, value), do: "**#{heading}:** #{value}"

  defp error_evaluation(proposal, perspective, evaluator_id, reason) do
    Logger.warning("Advisory LLM error: #{reason}")

    case Evaluation.new(%{
           proposal_id: proposal.id,
           evaluator_id: evaluator_id,
           perspective: perspective,
           vote: :abstain,
           reasoning: reason,
           confidence: 0.0,
           concerns: [reason],
           recommendations: ["Retry or consult a different evaluator"],
           risk_score: 0.5,
           benefit_score: 0.0
         }) do
      {:ok, evaluation} ->
        {:ok, Evaluation.seal(evaluation)}

      {:error, _} = error ->
        error
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp generate_evaluator_id(perspective) do
    "advisory_llm_#{perspective}_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  end

  # ============================================================================
  # Council Agent Management (runtime bridge to arbor_agent)
  # ============================================================================

  @lifecycle_mod Arbor.Agent.Lifecycle
  @manager_mod Arbor.Agent.Manager
  @template_name "council_evaluator"

  @doc false
  def agent_system_available? do
    Code.ensure_loaded?(@lifecycle_mod) and
      function_exported?(@lifecycle_mod, :create, 2) and
      Code.ensure_loaded?(@manager_mod) and
      function_exported?(@manager_mod, :chat, 3)
  end

  @doc """
  Pre-create and start all council agents sequentially.

  Call this before parallel evaluation to avoid SessionManager contention
  when 13 agents try to create sessions simultaneously through a single GenServer.
  """
  def ensure_all_council_agents(opts \\ []) do
    if agent_system_available?() do
      Enum.each(@perspectives, fn perspective ->
        agent_name = "council-#{perspective}"
        {p, m} = resolve_provider_model(perspective, opts)
        provider_atom = parse_provider_atom(p)

        case find_council_agent(agent_name, provider_atom, m) do
          {:ok, _} ->
            :ok

          :not_found ->
            case create_council_agent(agent_name, perspective, p, m) do
              {:ok, _} ->
                Logger.info("Council agent ready: #{agent_name}")

              {:error, reason} ->
                Logger.warning("Failed to prepare #{agent_name}: #{inspect(reason)}")
            end
        end
      end)
    end
  end

  # Ensure a persistent council agent exists for the given perspective.
  # Creates the agent on first use via Lifecycle.create with the CouncilEvaluator template.
  # Returns {:ok, agent_id} if the agent is running or was successfully started.
  defp ensure_council_agent(agent_name, perspective, provider, model) do
    provider_atom = parse_provider_atom(provider)

    # Check if an agent with this name already exists
    case find_council_agent(agent_name, provider_atom, model) do
      {:ok, agent_id} ->
        {:ok, agent_id}

      :not_found ->
        create_council_agent(agent_name, perspective, provider, model)
    end
  end

  @api_agent_mod Arbor.Agent.APIAgent
  @executor_registry Arbor.Agent.ExecutorRegistry

  defp find_council_agent(agent_name, provider_atom, model) do
    if function_exported?(@manager_mod, :find_agent_by_name, 1) do
      case apply(@manager_mod, :find_agent_by_name, [agent_name]) do
        {:ok, agent_id} ->
          # Profile exists — check if APIAgent host is running
          case Registry.lookup(@executor_registry, {:host, agent_id}) do
            [{_pid, _}] ->
              {:ok, agent_id}

            [] ->
              # Profile persisted but not running — start it
              start_council_agent(agent_id, provider_atom, model)
          end

        _ ->
          :not_found
      end
    else
      :not_found
    end
  end

  defp start_council_agent(agent_id, provider_atom, model) do
    # Council agents need a session (for ToolLoop/tool execution) but
    # don't need heartbeat (they're query-only, not autonomous).
    # Use a longer session timeout since multiple agents may be creating
    # sessions sequentially through the single SessionManager GenServer.
    start_opts = [
      provider: provider_atom,
      model: model,
      start_heartbeat: false,
      session_timeout: 60_000
    ]

    case apply(@lifecycle_mod, :start, [agent_id, start_opts]) do
      {:ok, _pid} -> {:ok, agent_id}
      {:error, {:already_started, _pid}} -> {:ok, agent_id}
      _ -> :not_found
    end
  end

  defp create_council_agent(agent_name, perspective, provider, model) do
    Logger.info("Creating council agent: #{agent_name} (#{perspective})")

    provider_atom = parse_provider_atom(provider)

    create_opts = [
      template: @template_name,
      perspective: perspective,
      model_config: %{
        provider: provider_atom,
        model: model,
        runtime: :arbor
      }
    ]

    case apply(@lifecycle_mod, :create, [agent_name, create_opts]) do
      {:ok, profile} ->
        agent_id = profile.agent_id

        # Start the agent with a session (for ToolLoop) but no heartbeat.
        # Pass model explicitly so APIAgent uses the perspective's model.
        start_opts = [
          provider: provider_atom,
          model: model,
          start_heartbeat: false,
          session_timeout: 60_000
        ]

        case apply(@lifecycle_mod, :start, [agent_id, start_opts]) do
          {:ok, _pid} ->
            {:ok, agent_id}

          {:error, {:already_started, _pid}} ->
            {:ok, agent_id}

          {:error, reason} ->
            {:error, {:start_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:create_failed, reason}}
    end
  end

  # Query the council agent directly via APIAgent, bypassing Manager.chat
  # which requires Agent.Registry registration. Council agents only have
  # an APIAgent host (via ExecutorRegistry), no full registry entry.
  # Returns {:ok, %{text: ..., usage: ...}} to preserve cost tracking data.
  defp query_council_agent(agent_id, prompt, _timeout) do
    case Registry.lookup(@executor_registry, {:host, agent_id}) do
      [{pid, _}] ->
        case apply(@api_agent_mod, :query, [pid, prompt]) do
          {:ok, response} ->
            text = response[:text] || Map.get(response, :text, "")
            usage = response[:usage] || Map.get(response, :usage, %{})
            {:ok, %{text: text, usage: usage}}

          {:error, _} = error ->
            error
        end

      [] ->
        {:error, :agent_not_found}
    end
  end

  @known_providers ~w(openrouter anthropic openai gemini ollama)a

  defp parse_provider_atom(provider) when is_binary(provider) do
    case Enum.find(@known_providers, fn p -> Atom.to_string(p) == provider end) do
      nil -> String.to_existing_atom(provider)
      atom -> atom
    end
  rescue
    ArgumentError -> :openrouter
  end

  defp parse_provider_atom(provider) when is_atom(provider), do: provider
end
