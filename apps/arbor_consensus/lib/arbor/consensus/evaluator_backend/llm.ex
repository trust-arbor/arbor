defmodule Arbor.Consensus.EvaluatorBackend.LLM do
  @moduledoc """
  LLM-based evaluator backend.

  Uses an LLM to evaluate proposals from various perspectives
  (security, performance, architecture, etc.). Complements deterministic
  evaluators with subjective, nuanced analysis.

  ## Perspectives

  LLM evaluators are best suited for subjective analysis:

  - `:security_llm` — Analyzes code for security vulnerabilities
  - `:architecture_llm` — Reviews design patterns and maintainability
  - `:code_quality_llm` — Assesses code style and best practices

  ## Configuration

  The evaluator uses `Arbor.AI` by default, configurable via opts:

      Arbor.Consensus.submit(proposal,
        evaluator_backend: Arbor.Consensus.EvaluatorBackend.LLM,
        perspectives: [:security_llm],
        ai_module: MyCustomAI
      )

  ## Response Format

  The LLM is prompted to return JSON with vote and reasoning:

      {"vote": "approve", "reasoning": "...", "concerns": [...]}

  If JSON parsing fails, the evaluator attempts to detect the vote
  from the text and returns an `:abstain` if unable to determine.

  ## Timeout and Fallback

  LLM calls have configurable timeout (default: 60s). On timeout or
  error, the evaluator returns `:abstain` rather than blocking consensus.
  """

  @behaviour Arbor.Consensus.EvaluatorBackend

  alias Arbor.Consensus.Config
  alias Arbor.Contracts.Consensus.{Evaluation, Proposal}

  require Logger

  @supported_perspectives [
    :security_llm,
    :architecture_llm,
    :code_quality_llm,
    :performance_llm
  ]

  @impl true
  @spec evaluate(Proposal.t(), atom(), keyword()) :: {:ok, Evaluation.t()} | {:error, term()}
  def evaluate(%Proposal{} = proposal, perspective, opts \\ []) do
    evaluator_id = Keyword.get(opts, :evaluator_id, generate_evaluator_id(perspective))
    ai_module = Keyword.get(opts, :ai_module, default_ai_module())
    timeout = Keyword.get(opts, :timeout, Config.llm_evaluator_timeout())

    if perspective in @supported_perspectives do
      do_evaluate(proposal, perspective, evaluator_id, ai_module, timeout)
    else
      unsupported_perspective(proposal, perspective, evaluator_id)
    end
  end

  @doc """
  List supported perspectives for this backend.
  """
  @spec supported_perspectives() :: [atom()]
  def supported_perspectives, do: @supported_perspectives

  # ===========================================================================
  # Evaluation Logic
  # ===========================================================================

  defp do_evaluate(proposal, perspective, evaluator_id, ai_module, timeout) do
    system_prompt = system_prompt_for(perspective)
    user_prompt = format_proposal(proposal)

    Logger.debug(
      "LLM evaluator running for perspective: #{perspective} (timeout: #{timeout}ms)"
    )

    task =
      Task.async(fn ->
        ai_module.generate_text(user_prompt, [
          system_prompt: system_prompt,
          max_tokens: 2048,
          temperature: 0.3
        ])
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

  # ===========================================================================
  # System Prompts
  # ===========================================================================

  defp system_prompt_for(:security_llm) do
    """
    You are a security reviewer analyzing code changes. Focus on:
    - Injection vulnerabilities (SQL, command, XSS, template injection)
    - Authentication and authorization issues
    - Data exposure and privacy risks
    - Cryptographic weaknesses
    - Input validation and sanitization
    - OWASP Top 10 vulnerabilities

    Respond with valid JSON only:
    {"vote": "approve" or "reject", "reasoning": "your analysis", "concerns": ["list", "of", "concerns"]}

    Vote "approve" if no significant security issues found.
    Vote "reject" if security vulnerabilities are present.
    Be conservative - when in doubt, reject.
    """
  end

  defp system_prompt_for(:architecture_llm) do
    """
    You are an architecture reviewer analyzing code changes. Focus on:
    - Design pattern adherence and appropriateness
    - Module coupling and cohesion
    - API design quality and consistency
    - Separation of concerns
    - Dependency management
    - Maintainability and extensibility

    Respond with valid JSON only:
    {"vote": "approve" or "reject", "reasoning": "your analysis", "suggestions": ["list", "of", "suggestions"]}

    Vote "approve" if the architecture is sound.
    Vote "reject" if there are significant design issues.
    """
  end

  defp system_prompt_for(:code_quality_llm) do
    """
    You are a code quality reviewer. Focus on:
    - Code clarity and readability
    - Naming conventions
    - Function size and complexity
    - Error handling patterns
    - Documentation completeness
    - Test coverage indicators

    Respond with valid JSON only:
    {"vote": "approve" or "reject", "reasoning": "your analysis", "suggestions": ["list", "of", "suggestions"]}

    Vote "approve" if code quality is acceptable.
    Vote "reject" if there are significant quality issues.
    """
  end

  defp system_prompt_for(:performance_llm) do
    """
    You are a performance reviewer analyzing code changes. Focus on:
    - Algorithmic complexity (O(n), O(n^2), etc.)
    - Memory allocation patterns
    - Database query efficiency
    - Caching opportunities
    - Resource cleanup and leaks
    - Concurrency and parallelism

    Respond with valid JSON only:
    {"vote": "approve" or "reject", "reasoning": "your analysis", "concerns": ["list", "of", "concerns"]}

    Vote "approve" if no significant performance issues.
    Vote "reject" if performance problems are likely.
    """
  end

  defp system_prompt_for(perspective) do
    """
    You are a code reviewer with #{perspective} expertise.
    Evaluate the proposed change and provide your assessment.

    Respond with valid JSON only:
    {"vote": "approve" or "reject", "reasoning": "your explanation"}
    """
  end

  # ===========================================================================
  # Proposal Formatting
  # ===========================================================================

  defp format_proposal(proposal) do
    """
    ## Proposal: #{proposal.id}

    **Type:** #{proposal.change_type}
    **Proposer:** #{proposal.proposer}
    **Target Layer:** #{proposal.target_layer}

    ### Description
    #{proposal.description}

    ### Code Diff
    ```
    #{proposal.code_diff || "No diff provided"}
    ```

    ### New Code
    ```elixir
    #{proposal.new_code || "No new code provided"}
    ```

    ### Metadata
    #{format_metadata(proposal.metadata)}
    """
  end

  defp format_metadata(metadata) when map_size(metadata) == 0, do: "None"

  defp format_metadata(metadata) do
    Enum.map_join(metadata, "\n", fn {k, v} -> "- #{k}: #{inspect(v)}" end)
  end

  # ===========================================================================
  # Response Parsing
  # ===========================================================================

  defp parse_llm_response(response, proposal, perspective, evaluator_id) do
    text = response.text

    case Jason.decode(text) do
      {:ok, %{"vote" => vote_str} = json} ->
        vote = parse_vote(vote_str)
        reasoning = json["reasoning"] || text

        evidence = %{
          concerns: json["concerns"] || [],
          suggestions: json["suggestions"] || [],
          model: response.model,
          provider: response.provider,
          usage: response.usage
        }

        build_evaluation(proposal, perspective, evaluator_id, vote, reasoning, evidence)

      {:error, _} ->
        # Fallback: try to detect vote from text
        vote = detect_vote_from_text(text)

        evidence = %{
          parse_error: true,
          raw_response: String.slice(text, 0, 500),
          model: response.model,
          provider: response.provider
        }

        build_evaluation(proposal, perspective, evaluator_id, vote, text, evidence)
    end
  end

  defp parse_vote("approve"), do: :approve
  defp parse_vote("reject"), do: :reject
  defp parse_vote(_), do: :abstain

  defp detect_vote_from_text(text) do
    lower = String.downcase(text)

    cond do
      json_vote_approve?(lower) -> :approve
      json_vote_reject?(lower) -> :reject
      has_only_approve?(lower) -> :approve
      has_only_reject?(lower) -> :reject
      true -> :abstain
    end
  end

  defp json_vote_approve?(text) do
    String.contains?(text, "\"vote\": \"approve\"") or
      String.contains?(text, "\"vote\":\"approve\"")
  end

  defp json_vote_reject?(text) do
    String.contains?(text, "\"vote\": \"reject\"") or
      String.contains?(text, "\"vote\":\"reject\"")
  end

  defp has_only_approve?(text) do
    String.contains?(text, "approve") and not String.contains?(text, "reject")
  end

  defp has_only_reject?(text) do
    String.contains?(text, "reject") and not String.contains?(text, "approve")
  end

  # ===========================================================================
  # Evaluation Building
  # ===========================================================================

  defp build_evaluation(proposal, perspective, evaluator_id, vote, reasoning, evidence) do
    confidence = vote_confidence(vote, evidence)
    concerns = Map.get(evidence, :concerns, [])
    recommendations = Map.get(evidence, :suggestions, [])

    case Evaluation.new(%{
           proposal_id: proposal.id,
           evaluator_id: evaluator_id,
           perspective: perspective,
           vote: vote,
           reasoning: reasoning,
           confidence: confidence,
           concerns: concerns,
           recommendations: recommendations,
           risk_score: risk_score_for(vote, evidence),
           benefit_score: benefit_score_for(vote, evidence)
         }) do
      {:ok, evaluation} ->
        {:ok, Evaluation.seal(evaluation)}

      {:error, _} = error ->
        error
    end
  end

  defp vote_confidence(:abstain, _), do: 0.0
  defp vote_confidence(_, %{parse_error: true}), do: 0.5
  defp vote_confidence(_, _), do: 0.8

  defp risk_score_for(:reject, evidence) do
    # Higher risk if more concerns
    base = 0.7
    concerns = Map.get(evidence, :concerns, [])
    min(1.0, base + length(concerns) * 0.05)
  end

  defp risk_score_for(:approve, _), do: 0.2
  defp risk_score_for(:abstain, _), do: 0.5

  defp benefit_score_for(:approve, _), do: 0.8
  defp benefit_score_for(:reject, _), do: 0.2
  defp benefit_score_for(:abstain, _), do: 0.5

  defp abstain_evaluation(proposal, perspective, evaluator_id, reason) do
    Logger.warning("LLM evaluator abstaining: #{reason}")

    case Evaluation.new(%{
           proposal_id: proposal.id,
           evaluator_id: evaluator_id,
           perspective: perspective,
           vote: :abstain,
           reasoning: reason,
           confidence: 0.0,
           concerns: ["LLM evaluation failed: #{reason}"],
           recommendations: ["Retry with deterministic evaluator or manual review"],
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
    supported = Enum.join(@supported_perspectives, ", ")

    case Evaluation.new(%{
           proposal_id: proposal.id,
           evaluator_id: evaluator_id,
           perspective: perspective,
           vote: :abstain,
           reasoning:
             "Unsupported LLM perspective: #{perspective}. " <>
               "LLM backend supports: #{supported}",
           confidence: 0.0,
           concerns: ["Unsupported evaluation perspective"],
           recommendations: ["Use a supported LLM perspective or the Deterministic backend"],
           risk_score: 0.5,
           benefit_score: 0.0
         }) do
      {:ok, evaluation} ->
        {:ok, Evaluation.seal(evaluation)}

      {:error, _} = error ->
        error
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp generate_evaluator_id(perspective) do
    "eval_llm_#{perspective}_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  end

  defp default_ai_module do
    Application.get_env(:arbor_consensus, :llm_evaluator_ai_module, Arbor.AI)
  end
end
