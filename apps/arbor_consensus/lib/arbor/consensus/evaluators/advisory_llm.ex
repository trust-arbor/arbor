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
  - `:general` — broad analysis without a specific lens

  ## Model Diversity

  Each perspective has a default provider:model assignment, distributing
  evaluations across different models for genuine viewpoint diversity.
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

  The vote field is always `:approve` (irrelevant for advisory use) —
  the value is in the `reasoning` field which contains structured analysis.
  """

  @behaviour Arbor.Contracts.Consensus.Evaluator

  alias Arbor.Consensus.Config
  alias Arbor.Consensus.LLMBridge
  alias Arbor.Contracts.Consensus.{Evaluation, Proposal}

  require Logger

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
    :general
  ]

  @vision_doc_path Path.expand("../../../../../../VISION.md", __DIR__)

  # Default provider:model per perspective — distributes across 4 different
  # models via OpenRouter for genuine viewpoint diversity. Each perspective
  # can be individually configured at runtime via Application config or
  # `configure_perspective/2`.
  #
  # openrouter:openai/gpt-5-nano: security, consistency, performance, privacy
  # openrouter:moonshotai/kimi-k2.5: vision, brainstorming, emergence, capability
  # openrouter:x-ai/grok-4.1-fast: stability, resource_usage
  # openrouter:deepseek/deepseek-v3.2: user_experience, generalization, general
  #
  # Configure via:
  #   Application.put_env(:arbor_consensus, :perspective_models, %{
  #     security: "anthropic:claude-sonnet-4-5-20250929",
  #     brainstorming: "openrouter:moonshotai/kimi-k2.5",
  #     ...
  #   })
  @default_perspective_models %{
    # All routed through OpenRouter for diverse, inexpensive viewpoint diversity.
    # Override per-perspective at runtime via configure_perspective/2 or
    # Application config :arbor_consensus, :perspective_models.
    security: "openrouter:openai/gpt-5-nano",
    vision: "openrouter:moonshotai/kimi-k2.5",
    consistency: "openrouter:openai/gpt-5-nano",
    performance: "openrouter:openai/gpt-5-nano",
    privacy: "openrouter:openai/gpt-5-nano",
    brainstorming: "openrouter:moonshotai/kimi-k2.5",
    emergence: "openrouter:moonshotai/kimi-k2.5",
    capability: "openrouter:moonshotai/kimi-k2.5",
    stability: "openrouter:x-ai/grok-4.1-fast",
    resource_usage: "openrouter:x-ai/grok-4.1-fast",
    user_experience: "openrouter:deepseek/deepseek-v3.2",
    generalization: "openrouter:deepseek/deepseek-v3.2",
    general: "openrouter:deepseek/deepseek-v3.2"
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

  Reads from application config (`:arbor_consensus, :perspective_models`),
  falling back to compiled defaults. Each perspective can be individually
  overridden at runtime via `configure_perspective/2`.
  """
  @spec provider_map() :: %{atom() => String.t()}
  def provider_map do
    configured = Application.get_env(:arbor_consensus, :perspective_models, %{})
    Map.merge(@default_perspective_models, configured)
  end

  @doc """
  Configure the provider:model for a specific perspective at runtime.

  ## Examples

      AdvisoryLLM.configure_perspective(:security, "anthropic:claude-sonnet-4-5-20250929")
      AdvisoryLLM.configure_perspective(:brainstorming, "gemini:gemini-2.5-pro")
      AdvisoryLLM.configure_perspective(:performance, "ollama:qwen3-coder:latest")
  """
  @spec configure_perspective(atom(), String.t()) :: :ok
  def configure_perspective(perspective, provider_model)
      when perspective in @perspectives and is_binary(provider_model) do
    current = Application.get_env(:arbor_consensus, :perspective_models, %{})
    Application.put_env(:arbor_consensus, :perspective_models, Map.put(current, perspective, provider_model))
  end

  @doc """
  Configure provider:model for multiple perspectives at once.

  ## Examples

      AdvisoryLLM.configure_perspectives(%{
        security: "anthropic:claude-sonnet-4-5-20250929",
        brainstorming: "gemini:gemini-2.5-pro",
        stability: "ollama:llama3.2:latest"
      })
  """
  @spec configure_perspectives(%{atom() => String.t()}) :: :ok
  def configure_perspectives(perspective_models) when is_map(perspective_models) do
    current = Application.get_env(:arbor_consensus, :perspective_models, %{})
    merged = Map.merge(current, perspective_models)
    Application.put_env(:arbor_consensus, :perspective_models, merged)
  end

  @doc """
  Reset all perspective models to compiled defaults.
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
    timeout = Keyword.get(opts, :timeout, Config.llm_evaluator_timeout())
    evaluator_id = generate_evaluator_id(perspective)

    system_prompt = load_system_prompt(perspective)
    doc_paths = collect_doc_paths(proposal, perspective)
    user_prompt = format_proposal(proposal, perspective, doc_paths)

    {provider, model} = resolve_provider_model(perspective, opts)

    Logger.debug(
      "Advisory LLM evaluating #{perspective} " <>
        "(provider: #{provider}, model: #{model}, timeout: #{timeout}ms)"
    )

    # Support :llm_fn override for testing (same pattern as orchestrator handlers)
    backend = Keyword.get(opts, :backend)

    llm_fn =
      Keyword.get_lazy(opts, :llm_fn, fn ->
        fn sys, usr ->
          bridge_opts = [
            provider: provider,
            model: model,
            max_tokens: Keyword.get(opts, :max_tokens, 4096),
            temperature: Keyword.get(opts, :temperature, 0.7)
          ]

          bridge_opts =
            if backend, do: Keyword.put(bridge_opts, :backend, backend), else: bridge_opts

          LLMBridge.complete(sys, usr, bridge_opts)
        end
      end)

    task = Task.async(fn -> llm_fn.(system_prompt, user_prompt) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, response_text}} ->
        build_advisory_evaluation(response_text, proposal, perspective, evaluator_id)

      {:ok, {:error, reason}} ->
        error_evaluation(proposal, perspective, evaluator_id, "LLM error: #{inspect(reason)}")

      nil ->
        error_evaluation(proposal, perspective, evaluator_id, "LLM timeout after #{timeout}ms")
    end
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

    parse_provider_model(provider_model)
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

  defp load_from_skill_library(skill_name) do
    if Code.ensure_loaded?(Arbor.Common.SkillLibrary) do
      case Arbor.Common.SkillLibrary.get(skill_name) do
        {:ok, skill} when is_binary(skill.body) and byte_size(skill.body) > 0 ->
          {:ok, skill.body}

        {:ok, _skill} ->
          {:error, :empty_body}

        {:error, _} = error ->
          error
      end
    else
      {:error, :skill_library_not_available}
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
    You will be given reference file paths to read, including Arbor's VISION.md.
    Use it as your primary reference for what Arbor should become.

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

  defp fallback_system_prompt(:general) do
    """
    #{@arbor_context}

    Your role is GENERAL ADVISORY: provide broad analysis across all dimensions.
    Consider security, performance, usability, architecture, and alignment with
    Arbor's patterns — whatever is most relevant to the question at hand.

    Focus on:
    - What are the most important considerations for this design?
    - What trade-offs are being made, and are they the right ones?
    - What would you want to know before approving this change?
    - Are there risks or opportunities that a focused perspective might miss?
    - Does this feel right for where Arbor is today and where it's heading?
    - What's the simplest thing that could work?

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
    context_section =
      case format_context(proposal.context) do
        "" -> ""
        formatted -> "\n### Context\n#{formatted}\n"
      end

    new_code = Map.get(proposal.context, :new_code)
    code_diff = Map.get(proposal.context, :code_diff)

    doc_section = format_doc_paths(doc_paths)

    """
    ## Advisory Request (#{perspective})

    ### Question/Description
    #{proposal.description}
    #{context_section}
    ### Topic
    #{proposal.topic}

    ### Target Layer
    #{proposal.target_layer}

    #{doc_section}#{if new_code, do: "### Proposed Code\n```elixir\n#{new_code}\n```\n", else: ""}
    #{if code_diff, do: "### Code Diff\n```\n#{code_diff}\n```\n", else: ""}
    """
  end

  defp format_doc_paths([]), do: ""

  defp format_doc_paths(doc_paths) do
    paths_section = Enum.map_join(doc_paths, "\n", &"- #{&1}")

    """
    ### Reference Documents

    Read the following files for additional context before responding:
    #{paths_section}

    """
  end

  defp format_context(context) when map_size(context) == 0, do: ""

  defp format_context(context) do
    context
    |> Enum.reject(fn {k, _v} -> k == :reference_docs end)
    |> Enum.map_join("\n", fn {k, v} -> "- **#{k}:** #{inspect(v)}" end)
  end

  # ============================================================================
  # Response Parsing
  # ============================================================================

  defp build_advisory_evaluation(response_text, proposal, perspective, evaluator_id) do
    reasoning = parse_advisory_response(response_text)

    case Evaluation.new(%{
           proposal_id: proposal.id,
           evaluator_id: evaluator_id,
           perspective: perspective,
           vote: :approve,
           reasoning: reasoning,
           confidence: 0.8,
           concerns: [],
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
end
