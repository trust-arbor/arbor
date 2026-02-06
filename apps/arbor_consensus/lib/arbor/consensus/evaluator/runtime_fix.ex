defmodule Arbor.Consensus.Evaluator.RuntimeFix do
  @moduledoc """
  Focused LLM evaluator for runtime fix proposals.

  Uses direct LLM calls (Arbor.AI) for fast evaluation of DebugAgent proposals.
  Only 3 perspectives for quick consensus on healing actions:

  - `:security` — Is the fix safe? Could it be exploited?
  - `:stability` — Will this cause cascading failures?
  - `:resource` — Is the resource cost acceptable?

  ## Usage

  Designed to be used with the `:runtime_fix` TopicRule:

      TopicRegistry.register_topic(%TopicRule{
        topic: :runtime_fix,
        required_evaluators: [Arbor.Consensus.Evaluator.RuntimeFix],
        min_quorum: :majority,
        ...
      })

  ## Response Format

  Each perspective returns a vote (:approve/:reject/:abstain) with reasoning.
  Majority approval (2/3) is required for the fix to proceed.
  """

  @behaviour Arbor.Contracts.Consensus.Evaluator

  alias Arbor.Consensus.Config
  alias Arbor.Contracts.Consensus.{Evaluation, Proposal}

  require Logger

  @perspectives [:security, :stability, :resource]

  # ===========================================================================
  # Evaluator Behaviour Callbacks
  # ===========================================================================

  @impl Arbor.Contracts.Consensus.Evaluator
  @spec name() :: atom()
  def name, do: :runtime_fix

  @impl Arbor.Contracts.Consensus.Evaluator
  @spec perspectives() :: [atom()]
  def perspectives, do: @perspectives

  @impl Arbor.Contracts.Consensus.Evaluator
  @spec strategy() :: :llm
  def strategy, do: :llm

  # ===========================================================================
  # Evaluate Callback
  # ===========================================================================

  @impl Arbor.Contracts.Consensus.Evaluator
  @spec evaluate(Proposal.t(), atom(), keyword()) :: {:ok, Evaluation.t()} | {:error, term()}
  def evaluate(%Proposal{} = proposal, perspective, opts \\ []) do
    evaluator_id = Keyword.get(opts, :evaluator_id, "runtime_fix_#{perspective}")
    ai_module = Keyword.get(opts, :ai_module, default_ai_module())
    timeout = Keyword.get(opts, :timeout, Config.llm_evaluator_timeout())

    if perspective in @perspectives do
      do_evaluate(proposal, perspective, evaluator_id, ai_module, timeout)
    else
      unsupported_perspective(proposal, perspective, evaluator_id)
    end
  end

  # ===========================================================================
  # Private Implementation
  # ===========================================================================

  defp do_evaluate(proposal, perspective, evaluator_id, ai_module, timeout) do
    prompt = build_prompt(proposal, perspective)

    task =
      Task.async(fn ->
        # Force API backend for speed (uses configured OpenRouter model)
        ai_module.generate_text(prompt, backend: :api, max_tokens: 500)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, response}} ->
        parse_response(proposal, perspective, evaluator_id, response)

      {:ok, {:error, reason}} ->
        Logger.warning("[RuntimeFixEvaluator] LLM error for #{perspective}: #{inspect(reason)}")
        abstain_evaluation(proposal, perspective, evaluator_id, "LLM error: #{inspect(reason)}")

      nil ->
        Logger.warning("[RuntimeFixEvaluator] Timeout for #{perspective}")
        abstain_evaluation(proposal, perspective, evaluator_id, "Evaluation timed out")
    end
  end

  defp build_prompt(proposal, :security) do
    """
    You are evaluating a runtime fix proposal from a security perspective.

    ## Proposal
    #{format_proposal(proposal)}

    ## Your Task
    Evaluate whether this fix is SAFE from a security standpoint:
    - Could this fix be exploited by an attacker?
    - Does it maintain proper process isolation?
    - Are there any privilege escalation risks?
    - Could it leak sensitive information?

    ## Response Format
    Respond with EXACTLY this JSON (no markdown, no extra text):
    {"vote": "approve|reject|abstain", "reasoning": "your analysis here", "concerns": ["list", "of", "concerns"]}
    """
  end

  defp build_prompt(proposal, :stability) do
    """
    You are evaluating a runtime fix proposal from a stability perspective.

    ## Proposal
    #{format_proposal(proposal)}

    ## Your Task
    Evaluate whether this fix is STABLE and won't cause cascading failures:
    - Will terminating/restarting this process affect other processes?
    - Are there supervision tree implications?
    - Could this trigger a restart storm?
    - Is the fix scoped appropriately (not too broad)?

    ## Response Format
    Respond with EXACTLY this JSON (no markdown, no extra text):
    {"vote": "approve|reject|abstain", "reasoning": "your analysis here", "concerns": ["list", "of", "concerns"]}
    """
  end

  defp build_prompt(proposal, :resource) do
    """
    You are evaluating a runtime fix proposal from a resource perspective.

    ## Proposal
    #{format_proposal(proposal)}

    ## Your Task
    Evaluate whether the resource cost of this fix is acceptable:
    - Is the fix proportional to the problem?
    - Will it consume excessive memory/CPU during execution?
    - Are there cheaper alternatives?
    - Is this a one-time cost or recurring?

    ## Response Format
    Respond with EXACTLY this JSON (no markdown, no extra text):
    {"vote": "approve|reject|abstain", "reasoning": "your analysis here", "concerns": ["list", "of", "concerns"]}
    """
  end

  defp format_proposal(proposal) do
    context = proposal.context || %{}

    """
    **Topic:** #{proposal.topic}
    **Description:** #{proposal.description}
    **Proposer:** #{Map.get(context, :proposer, "unknown")}

    **Anomaly Details:**
    - Skill: #{Map.get(context, :skill, "unknown")}
    - Severity: #{Map.get(context, :severity, "unknown")}
    - Metric: #{Map.get(context, :metric, "unknown")}
    - Value: #{Map.get(context, :value, "unknown")}
    - Threshold: #{Map.get(context, :threshold, "unknown")}

    **Diagnosis:**
    #{Map.get(context, :root_cause, "Not provided")}

    **Proposed Fix:**
    #{Map.get(context, :recommended_fix, "Not provided")}
    """
  end

  defp parse_response(proposal, perspective, evaluator_id, response) do
    case extract_json(response) do
      {:ok, %{"vote" => vote_str, "reasoning" => reasoning} = parsed} ->
        vote = parse_vote(vote_str)
        concerns = Map.get(parsed, "concerns", [])

        evaluation = %Evaluation{
          id: generate_evaluation_id(proposal.id, perspective),
          proposal_id: proposal.id,
          evaluator_id: evaluator_id,
          perspective: perspective,
          vote: vote,
          reasoning: reasoning,
          concerns: concerns,
          confidence: if(vote == :abstain, do: 0.0, else: 0.8),
          created_at: DateTime.utc_now()
        }

        {:ok, evaluation}

      {:error, _reason} ->
        # Try to detect vote from text
        vote = detect_vote_from_text(response)

        evaluation = %Evaluation{
          id: generate_evaluation_id(proposal.id, perspective),
          proposal_id: proposal.id,
          evaluator_id: evaluator_id,
          perspective: perspective,
          vote: vote,
          reasoning: response,
          concerns: [],
          confidence: 0.5,
          created_at: DateTime.utc_now()
        }

        {:ok, evaluation}
    end
  end

  defp extract_json(text) do
    # Try to find JSON in the response
    case Regex.run(~r/\{[^}]+\}/s, text) do
      [json_str] ->
        case Jason.decode(json_str) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, reason} -> {:error, reason}
        end

      nil ->
        {:error, :no_json_found}
    end
  end

  defp parse_vote("approve"), do: :approve
  defp parse_vote("reject"), do: :reject
  defp parse_vote("abstain"), do: :abstain
  defp parse_vote(_), do: :abstain

  defp detect_vote_from_text(text) do
    text_lower = String.downcase(text)

    cond do
      String.contains?(text_lower, "approve") and not String.contains?(text_lower, "reject") ->
        :approve

      String.contains?(text_lower, "reject") ->
        :reject

      true ->
        :abstain
    end
  end

  defp unsupported_perspective(proposal, perspective, evaluator_id) do
    evaluation = %Evaluation{
      id: generate_evaluation_id(proposal.id, perspective),
      proposal_id: proposal.id,
      evaluator_id: evaluator_id,
      perspective: perspective,
      vote: :abstain,
      reasoning: "Perspective #{perspective} not supported by RuntimeFixEvaluator",
      concerns: [],
      confidence: 0.0,
      created_at: DateTime.utc_now()
    }

    {:ok, evaluation}
  end

  defp abstain_evaluation(proposal, perspective, evaluator_id, reason) do
    evaluation = %Evaluation{
      id: generate_evaluation_id(proposal.id, perspective),
      proposal_id: proposal.id,
      evaluator_id: evaluator_id,
      perspective: perspective,
      vote: :abstain,
      reasoning: reason,
      concerns: [],
      confidence: 0.0,
      created_at: DateTime.utc_now()
    }

    {:ok, evaluation}
  end

  defp generate_evaluation_id(proposal_id, perspective) do
    "#{proposal_id}_#{perspective}_#{:erlang.unique_integer([:positive])}"
  end

  defp default_ai_module do
    Application.get_env(:arbor_consensus, :llm_evaluator_ai_module, Arbor.AI)
  end
end
