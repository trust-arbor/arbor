defmodule Arbor.SDLC.Evaluator do
  @moduledoc """
  SDLC-specific evaluator backend for consensus council.

  Evaluates SDLC planning proposals from 7 perspectives relevant to
  software development lifecycle decisions:

  | Perspective | Role |
  |-------------|------|
  | `:scope` | Scope clarity, acceptance criteria quality, splitting opportunities |
  | `:feasibility` | Buildability, dependency gaps, effort realism |
  | `:priority` | Roadmap-relative priority, blocking analysis |
  | `:architecture` | Library hierarchy fit, contract-first compliance |
  | `:consistency` | Alignment with VISION.md, component docs, decisions, CLAUDE.md |
  | `:adversarial` | Risks, failure modes, security implications |
  | `:random` | Groupthink prevention (intentional unpredictability) |

  ## Usage

  Register as the evaluator backend for SDLC decisions:

      Arbor.Consensus.propose(attrs,
        evaluator_backend: Arbor.SDLC.Evaluator,
        topic: :sdlc_decision
      )

  ## Context Loading

  The consistency perspective loads context from a hierarchical set of documents:

  1. `VISION.md` — North star alignment
  2. Component vision docs (`docs/arbor-*-vision.md`)
  3. `.arbor/decisions/` — Existing design decisions
  4. `CLAUDE.md` — Architecture patterns

  ## LLM-Based Evaluation

  All perspectives are LLM-based. Each perspective gets a specialized system
  prompt and evaluates the proposal using AI. The random perspective introduces
  intentional unpredictability to prevent groupthink.
  """

  @behaviour Arbor.Consensus.EvaluatorBackend
  @behaviour Arbor.Contracts.Consensus.Evaluator

  require Logger

  alias Arbor.Contracts.Consensus.{Evaluation, Proposal}
  alias Arbor.SDLC.Config

  @perspectives [
    :scope,
    :feasibility,
    :priority,
    :architecture,
    :consistency,
    :adversarial,
    :random
  ]

  # =============================================================================
  # Evaluator Behaviour Callbacks
  # =============================================================================

  @doc """
  Unique name identifying this evaluator.
  """
  @impl Arbor.Contracts.Consensus.Evaluator
  @spec name() :: atom()
  def name, do: :sdlc

  @doc """
  Perspectives this evaluator can assess from.
  """
  @impl Arbor.Contracts.Consensus.Evaluator
  @spec perspectives() :: [atom()]
  def perspectives, do: @perspectives

  @doc """
  Strategy this evaluator uses.
  """
  @impl Arbor.Contracts.Consensus.Evaluator
  @spec strategy() :: :llm
  def strategy, do: :llm

  # =============================================================================
  # Evaluate Callback (shared by both behaviours)
  # =============================================================================

  # Note: Both EvaluatorBackend and Evaluator define evaluate/3. The @impl is
  # for the Evaluator behaviour since EvaluatorBackend is being deprecated.
  @impl Arbor.Contracts.Consensus.Evaluator
  @spec evaluate(Proposal.t(), atom(), keyword()) :: {:ok, Evaluation.t()} | {:error, term()}
  def evaluate(%Proposal{} = proposal, perspective, opts \\ []) do
    evaluator_id = Keyword.get(opts, :evaluator_id, generate_evaluator_id(perspective))
    ai_module = Keyword.get(opts, :ai_module, default_ai_module())
    timeout = Keyword.get(opts, :timeout, Config.ai_timeout())

    if perspective in @perspectives do
      do_evaluate(proposal, perspective, evaluator_id, ai_module, timeout, opts)
    else
      unsupported_perspective(proposal, perspective, evaluator_id)
    end
  end

  @doc """
  List supported SDLC perspectives.

  Deprecated: Use `perspectives/0` instead.
  """
  @spec supported_perspectives() :: [atom()]
  def supported_perspectives, do: @perspectives

  # =============================================================================
  # Evaluation Logic
  # =============================================================================

  defp do_evaluate(proposal, perspective, evaluator_id, ai_module, timeout, opts) do
    system_prompt = system_prompt_for(perspective, opts)
    user_prompt = format_proposal_for_sdlc(proposal, perspective, opts)
    ai_backend = Keyword.get(opts, :ai_backend, Config.new().ai_backend)

    Logger.debug("SDLC evaluator running perspective: #{perspective}")

    task =
      Task.async(fn ->
        ai_module.generate_text(user_prompt,
          system_prompt: system_prompt,
          max_tokens: 2048,
          temperature: temperature_for(perspective),
          backend: ai_backend
        )
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, response}} ->
        parse_llm_response(response, proposal, perspective, evaluator_id)

      {:ok, {:error, reason}} ->
        abstain_evaluation(proposal, perspective, evaluator_id, "LLM error: #{inspect(reason)}")

      nil ->
        abstain_evaluation(proposal, perspective, evaluator_id, "LLM timeout after #{timeout}ms")
    end
  end

  defp temperature_for(:random), do: 0.9
  defp temperature_for(_), do: 0.3

  # =============================================================================
  # System Prompts
  # =============================================================================

  defp system_prompt_for(:scope, _opts) do
    """
    You are a scope reviewer for software development planning decisions.

    Your role is to evaluate whether a work item has clear, well-defined scope:
    - Are the acceptance criteria specific and testable?
    - Is the scope appropriate for a single work item, or should it be split?
    - Are there ambiguities that need clarification?
    - Is it clear what "done" means for this item?

    Respond with valid JSON only:
    {"vote": "approve" or "reject", "reasoning": "your analysis", "concerns": ["list"], "recommendations": ["list"]}

    Vote "approve" if scope is clear enough to begin work.
    Vote "reject" if scope is too vague, too large, or has critical ambiguities.
    """
  end

  defp system_prompt_for(:feasibility, _opts) do
    """
    You are a feasibility reviewer for software development planning decisions.

    Your role is to evaluate whether a work item can realistically be built:
    - Are the required dependencies available?
    - Is the effort estimate reasonable for the scope?
    - Are there technical blockers or unknowns that need resolution first?
    - Does the team have the capabilities to deliver this?

    Consider this is an Elixir/OTP umbrella project with modular architecture.

    Respond with valid JSON only:
    {"vote": "approve" or "reject", "reasoning": "your analysis", "concerns": ["list"], "recommendations": ["list"]}

    Vote "approve" if the item is feasible with current capabilities.
    Vote "reject" if there are significant blockers or unrealistic expectations.
    """
  end

  defp system_prompt_for(:priority, _opts) do
    """
    You are a priority reviewer for software development planning decisions.

    Your role is to evaluate whether the item's priority is appropriate:
    - Does the priority align with the overall roadmap goals?
    - Is this item blocking other high-priority work?
    - Should this be deprioritized in favor of other items?
    - Are dependencies properly ordered?

    Respond with valid JSON only:
    {"vote": "approve" or "reject", "reasoning": "your analysis", "concerns": ["list"], "recommendations": ["list"]}

    Vote "approve" if the priority seems appropriate.
    Vote "reject" if the priority should be reconsidered.
    """
  end

  defp system_prompt_for(:architecture, _opts) do
    """
    You are an architecture reviewer for software development planning decisions.

    Your role is to evaluate architectural fit:
    - Does this fit the library hierarchy? (No cycles, no skipping levels)
    - Does it follow contract-first design principles?
    - Are dependencies between libraries appropriate?
    - Does it use facades rather than reaching into internal modules?
    - Are security patterns (SafeAtom, SafePath, FileGuard) considered?

    This is an Elixir/OTP umbrella project with levels:
    - Level 0: contracts, common, flow (zero deps)
    - Level 1: signals, shell, security, consensus, historian, persistence, web, sandbox
    - Level 2: trust, actions, agent, gateway, sdlc, memory
    - Standalone: checkpoint, eval, ai, comms (zero in-umbrella deps)

    Respond with valid JSON only:
    {"vote": "approve" or "reject", "reasoning": "your analysis", "concerns": ["list"], "recommendations": ["list"]}

    Vote "approve" if the item respects architectural boundaries.
    Vote "reject" if it would violate hierarchy or design patterns.
    """
  end

  defp system_prompt_for(:consistency, opts) do
    context = load_consistency_context(opts)

    """
    You are a consistency reviewer for software development planning decisions.

    Your role is to evaluate alignment with existing vision and decisions:
    - Does this align with the project VISION?
    - Does it contradict any existing design decisions?
    - Is it consistent with the documented architecture in CLAUDE.md?
    - Does it fit the component's vision (if applicable)?

    ## Project Context

    #{context}

    Respond with valid JSON only:
    {"vote": "approve" or "reject", "reasoning": "your analysis", "concerns": ["list"], "recommendations": ["list"]}

    Vote "approve" if the item is consistent with existing vision and decisions.
    Vote "reject" if it contradicts established patterns or decisions.
    """
  end

  defp system_prompt_for(:adversarial, _opts) do
    """
    You are an adversarial reviewer for software development planning decisions.

    Your role is to identify risks and failure modes:
    - What could go wrong during implementation?
    - What are the risks of doing this vs. not doing it?
    - Are there security implications?
    - What assumptions might be wrong?
    - How might this fail in production?

    Be pessimistic and thorough. Your job is to find problems others might miss.

    Respond with valid JSON only:
    {"vote": "approve" or "reject", "reasoning": "your analysis", "concerns": ["list"], "recommendations": ["list"]}

    Vote "approve" if risks are acceptable and manageable.
    Vote "reject" if there are unacceptable or unaddressed risks.
    """
  end

  defp system_prompt_for(:random, _opts) do
    """
    You are a wildcard reviewer for software development planning decisions.

    Your role is to prevent groupthink by offering unexpected perspectives:
    - Challenge assumptions that seem obvious
    - Suggest alternative approaches nobody has considered
    - Question whether the problem statement itself is correct
    - Bring in cross-domain insights

    Be creative and unconventional. Your job is to shake up the discussion.

    Respond with valid JSON only:
    {"vote": "approve" or "reject", "reasoning": "your unconventional analysis", "concerns": ["list"], "recommendations": ["list"]}

    Your vote should be genuine but informed by your unique perspective.
    """
  end

  defp system_prompt_for(perspective, _opts) do
    """
    You are a reviewer with #{perspective} expertise evaluating an SDLC decision.
    Provide your assessment of the proposal.

    Respond with valid JSON only:
    {"vote": "approve" or "reject", "reasoning": "your explanation", "concerns": [], "recommendations": []}
    """
  end

  # =============================================================================
  # Context Loading for Consistency Perspective
  # =============================================================================

  defp load_consistency_context(opts) do
    sections = [
      load_vision_doc(opts),
      load_component_visions(opts),
      load_recent_decisions(opts),
      load_claude_md(opts)
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n---\n\n")
    |> case do
      "" -> "No project context documents found."
      context -> context
    end
  end

  defp load_vision_doc(_opts) do
    case File.read("VISION.md") do
      {:ok, content} ->
        """
        ### VISION.md (Project North Star)

        #{String.slice(content, 0, 3000)}
        """

      {:error, _} ->
        nil
    end
  end

  defp load_component_visions(_opts) do
    vision_dir = Config.component_vision_directory()

    case File.ls(vision_dir) do
      {:ok, files} ->
        visions =
          files
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.take(5)
          |> Enum.flat_map(&read_vision_file(vision_dir, &1))
          |> Enum.join("\n\n")

        if visions == "" do
          nil
        else
          """
          ### Component Vision Docs

          #{visions}
          """
        end

      {:error, _} ->
        nil
    end
  end

  defp read_vision_file(dir, file) do
    case File.read(Path.join(dir, file)) do
      {:ok, content} -> ["#### #{file}\n#{String.slice(content, 0, 1000)}"]
      {:error, _} -> []
    end
  end

  defp load_recent_decisions(_opts) do
    decisions_dir = Config.decisions_directory()

    case File.ls(decisions_dir) do
      {:ok, files} ->
        decisions =
          files
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.reject(&String.starts_with?(&1, "."))
          |> Enum.sort(:desc)
          |> Enum.take(5)
          |> Enum.flat_map(&read_decision_file(decisions_dir, &1))
          |> Enum.join("\n\n")

        if decisions == "" do
          nil
        else
          """
          ### Recent Design Decisions

          #{decisions}
          """
        end

      {:error, _} ->
        nil
    end
  end

  defp read_decision_file(dir, file) do
    case File.read(Path.join(dir, file)) do
      {:ok, content} -> ["#### #{file}\n#{String.slice(content, 0, 800)}"]
      {:error, _} -> []
    end
  end

  defp load_claude_md(_opts) do
    case File.read("CLAUDE.md") do
      {:ok, content} ->
        """
        ### CLAUDE.md (Architecture Patterns)

        #{String.slice(content, 0, 2500)}
        """

      {:error, _} ->
        nil
    end
  end

  # =============================================================================
  # Proposal Formatting
  # =============================================================================

  defp format_proposal_for_sdlc(proposal, _perspective, _opts) do
    """
    ## SDLC Decision Proposal

    **ID:** #{proposal.id}
    **Proposer:** #{proposal.proposer}
    **Type:** #{proposal.topic}

    ### Description
    #{proposal.description}

    ### Item Details
    #{format_item_details(proposal.metadata)}

    ### Context
    #{format_context(proposal.metadata)}
    """
  end

  defp format_item_details(metadata) when is_map(metadata) do
    item = Map.get(metadata, :item) || Map.get(metadata, "item") || %{}

    """
    - **Title:** #{item_field(item, :title, "Unknown")}
    - **Priority:** #{item_field(item, :priority, "Not set")}
    - **Category:** #{item_field(item, :category, "Not set")}
    - **Effort:** #{item_field(item, :effort, "Not set")}

    **Summary:**
    #{item_field(item, :summary, "No summary provided.")}

    **Acceptance Criteria:**
    #{format_criteria(item_field_raw(item, :acceptance_criteria))}
    """
  end

  defp format_item_details(_), do: "No item details available."

  defp item_field(item, key, default) do
    item_field_raw(item, key) || default
  end

  defp item_field_raw(item, key) do
    Map.get(item, key) || Map.get(item, to_string(key))
  end

  defp format_criteria(nil), do: "None specified."
  defp format_criteria([]), do: "None specified."

  defp format_criteria(criteria) when is_list(criteria) do
    criteria
    |> Enum.map(fn
      %{text: text} -> "- #{text}"
      %{"text" => text} -> "- #{text}"
      text when is_binary(text) -> "- #{text}"
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp format_context(metadata) when is_map(metadata) do
    context = Map.get(metadata, :context) || Map.get(metadata, "context") || %{}

    if map_size(context) == 0 do
      "No additional context provided."
    else
      Enum.map_join(context, "\n", fn {k, v} -> "- **#{k}:** #{inspect(v)}" end)
    end
  end

  defp format_context(_), do: "No context available."

  # =============================================================================
  # Response Parsing
  # =============================================================================

  defp parse_llm_response(response, proposal, perspective, evaluator_id) do
    text = Map.get(response, :text) || ""

    case Jason.decode(text) do
      {:ok, %{"vote" => vote_str} = json} ->
        vote = parse_vote(vote_str)
        reasoning = json["reasoning"] || text
        concerns = json["concerns"] || []
        recommendations = json["recommendations"] || []

        build_evaluation(
          proposal,
          perspective,
          evaluator_id,
          vote,
          reasoning,
          concerns,
          recommendations
        )

      {:error, _} ->
        # Fallback: try to detect vote from text
        vote = detect_vote_from_text(text)
        build_evaluation(proposal, perspective, evaluator_id, vote, text, [], [])
    end
  end

  defp parse_vote("approve"), do: :approve
  defp parse_vote("reject"), do: :reject
  defp parse_vote(_), do: :abstain

  defp detect_vote_from_text(text) do
    lower = String.downcase(text)

    cond do
      contains_vote_pattern?(lower, "approve") -> :approve
      contains_vote_pattern?(lower, "reject") -> :reject
      contains_only?(lower, "approve", "reject") -> :approve
      contains_only?(lower, "reject", "approve") -> :reject
      true -> :abstain
    end
  end

  defp contains_vote_pattern?(text, vote) do
    String.contains?(text, "\"vote\": \"#{vote}\"") or
      String.contains?(text, "\"vote\":\"#{vote}\"")
  end

  defp contains_only?(text, present, absent) do
    String.contains?(text, present) and not String.contains?(text, absent)
  end

  # =============================================================================
  # Evaluation Building
  # =============================================================================

  defp build_evaluation(
         proposal,
         perspective,
         evaluator_id,
         vote,
         reasoning,
         concerns,
         recommendations
       ) do
    confidence = vote_confidence(vote)

    case Evaluation.new(%{
           proposal_id: proposal.id,
           evaluator_id: evaluator_id,
           perspective: perspective,
           vote: vote,
           reasoning: reasoning,
           confidence: confidence,
           concerns: concerns,
           recommendations: recommendations,
           risk_score: risk_score_for(vote, concerns),
           benefit_score: benefit_score_for(vote)
         }) do
      {:ok, evaluation} ->
        {:ok, Evaluation.seal(evaluation)}

      {:error, _} = error ->
        error
    end
  end

  defp vote_confidence(:abstain), do: 0.0
  defp vote_confidence(_), do: 0.75

  defp risk_score_for(:reject, concerns) do
    base = 0.7
    min(1.0, base + length(concerns) * 0.05)
  end

  defp risk_score_for(:approve, _), do: 0.2
  defp risk_score_for(:abstain, _), do: 0.5

  defp benefit_score_for(:approve), do: 0.8
  defp benefit_score_for(:reject), do: 0.2
  defp benefit_score_for(:abstain), do: 0.5

  defp abstain_evaluation(proposal, perspective, evaluator_id, reason) do
    Logger.warning("SDLC evaluator abstaining: #{reason}")

    case Evaluation.new(%{
           proposal_id: proposal.id,
           evaluator_id: evaluator_id,
           perspective: perspective,
           vote: :abstain,
           reasoning: reason,
           confidence: 0.0,
           concerns: ["Evaluation failed: #{reason}"],
           recommendations: ["Manual review recommended"],
           risk_score: 0.5,
           benefit_score: 0.0
         }) do
      {:ok, evaluation} ->
        {:ok, Evaluation.seal(evaluation)}

      {:error, _} = error ->
        error
    end
  end

  defp unsupported_perspective(proposal, perspective, evaluator_id) do
    supported = Enum.join(@perspectives, ", ")

    case Evaluation.new(%{
           proposal_id: proposal.id,
           evaluator_id: evaluator_id,
           perspective: perspective,
           vote: :abstain,
           reasoning: "Unsupported SDLC perspective: #{perspective}. Supported: #{supported}",
           confidence: 0.0,
           concerns: ["Unsupported evaluation perspective"],
           recommendations: ["Use a supported SDLC perspective"],
           risk_score: 0.5,
           benefit_score: 0.0
         }) do
      {:ok, evaluation} ->
        {:ok, Evaluation.seal(evaluation)}

      {:error, _} = error ->
        error
    end
  end

  # =============================================================================
  # Helpers
  # =============================================================================

  defp generate_evaluator_id(perspective) do
    "eval_sdlc_#{perspective}_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  end

  defp default_ai_module do
    Application.get_env(:arbor_sdlc, :ai_module, Arbor.AI)
  end
end
