defmodule Arbor.Demo.EvaluatorConfig do
  @moduledoc """
  Evaluator configuration for the self-healing demo.

  Configures 3 evaluators for demo purposes (council recommendation: not 12):

  1. `:security_llm` — Checks for vulnerabilities in proposed fixes
  2. `:performance_llm` — Checks for performance regressions
  3. `:demo_deterministic` — Rule-based, ensures one rejection for demo credibility

  The deterministic evaluator applies strict rules to:
  - Reject proposals touching protected modules
  - Reject proposals without rollback plans
  - Reject high-impact changes without sufficient evidence

  ## Usage

      # Get evaluator specs for the demo
      specs = EvaluatorConfig.evaluator_specs()

      # Check if a module is protected
      EvaluatorConfig.protected_module?(Arbor.Security.Kernel)  # => true
  """

  alias Arbor.Contracts.Consensus.ChangeProposal
  alias Arbor.Contracts.Consensus.{Evaluation, Proposal}

  @behaviour Arbor.Contracts.Consensus.Evaluator

  # Protected modules that should never be hot-loaded automatically
  @protected_modules [
    # Security layer
    Arbor.Security,
    Arbor.Security.Kernel,
    Arbor.Security.CapabilityStore,
    Arbor.Security.FileGuard,
    Arbor.Security.TrustManager,
    # Persistence layer
    Arbor.Persistence,
    Arbor.Persistence.Store,
    Arbor.Checkpoint,
    # Consensus layer
    Arbor.Consensus,
    Arbor.Consensus.Coordinator,
    Arbor.Consensus.Council,
    # Agent core
    Arbor.Agent.Executor,
    Arbor.Agent.Lifecycle
  ]

  # Minimum evidence items for high-impact changes
  @min_evidence_for_high_impact 3

  # ============================================================================
  # Evaluator Behaviour Callbacks
  # ============================================================================

  @impl true
  def name, do: :demo_evaluator

  @impl true
  def perspectives do
    # Deterministic + LLM perspectives
    [:safety_check, :policy_compliance, :rollback_verification, :vulnerability_scan, :performance_impact]
  end

  @impl true
  def strategy, do: :hybrid

  @impl true
  def evaluate(%Proposal{} = proposal, perspective, opts) do
    evaluator_id = Keyword.get(opts, :evaluator_id, generate_evaluator_id(perspective))

    case perspective do
      # Deterministic perspectives (fast, rule-based)
      :safety_check -> check_safety(proposal, evaluator_id)
      :policy_compliance -> check_policy(proposal, evaluator_id)
      :rollback_verification -> check_rollback(proposal, evaluator_id)

      # LLM perspectives (use configured model)
      :vulnerability_scan -> evaluate_with_llm(proposal, perspective, evaluator_id, security_system_prompt())
      :performance_impact -> evaluate_with_llm(proposal, perspective, evaluator_id, performance_system_prompt())

      _ -> unsupported_perspective(proposal, perspective, evaluator_id)
    end
  end

  # LLM-based evaluation using configured model
  defp evaluate_with_llm(proposal, perspective, evaluator_id, system_prompt) do
    llm_config = get_llm_config()

    # Build options for LLM evaluator
    llm_opts = [
      evaluator_id: evaluator_id,
      model: Map.get(llm_config, :model),
      provider: Map.get(llm_config, :provider),
      system_prompt: system_prompt
    ] |> Enum.reject(fn {_, v} -> is_nil(v) end)

    # Delegate to LLM evaluator
    Arbor.Consensus.Evaluator.LLM.evaluate(proposal, perspective, llm_opts)
  end

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Get evaluator specifications for the demo.

  Returns a list of evaluator specs suitable for passing to the Coordinator.
  Model configuration is read from Application env, allowing runtime changes.

  ## Configuration

  Set via `Arbor.Demo.configure_evaluator_models/1`:

      Arbor.Demo.configure_evaluator_models(%{
        provider: :openrouter,
        model: "meta-llama/llama-3.3-70b-instruct"
      })
  """
  @spec evaluator_specs() :: [map()]
  def evaluator_specs do
    # Single evaluator for demo: handles deterministic + LLM perspectives
    # Use configure_evaluator_models/1 to change the LLM model used
    [
      %{
        module: __MODULE__,
        name: :demo_evaluator,
        perspectives: perspectives()
      }
    ]
  end

  @doc """
  Get the current LLM configuration for evaluators.
  """
  @spec get_llm_config() :: map()
  def get_llm_config do
    Application.get_env(:arbor_demo, :evaluator_llm_config, default_llm_config())
  end

  @doc """
  Set the LLM configuration for evaluators.

  ## Options

    * `:provider` - LLM provider (`:openrouter`, `:anthropic`, `:openai`, etc.)
    * `:model` - Model name/ID
    * `:api_key` - Optional API key override

  ## Examples

      # Use OpenRouter with a free model
      EvaluatorConfig.set_llm_config(%{
        provider: :openrouter,
        model: "meta-llama/llama-3.3-70b-instruct"
      })

      # Use Anthropic API
      EvaluatorConfig.set_llm_config(%{
        provider: :anthropic,
        model: "claude-sonnet-4-20250514"
      })
  """
  @spec set_llm_config(map()) :: :ok
  def set_llm_config(config) when is_map(config) do
    Application.put_env(:arbor_demo, :evaluator_llm_config, config)
  end

  defp default_llm_config do
    %{
      provider: :anthropic,
      model: "claude-sonnet-4-20250514"
    }
  end

  @doc """
  Check if a module is protected from automatic hot-loading.
  """
  @spec protected_module?(module()) :: boolean()
  def protected_module?(module) when is_atom(module) do
    module in @protected_modules or
      protected_namespace?(module)
  end

  @doc """
  Get the list of protected modules.
  """
  @spec protected_modules() :: [module()]
  def protected_modules, do: @protected_modules

  # ============================================================================
  # Safety Check Evaluation
  # ============================================================================

  defp check_safety(proposal, evaluator_id) do
    change_proposal = extract_change_proposal(proposal)

    cond do
      # Reject changes to protected modules
      change_proposal && protected_module?(change_proposal.module) ->
        reject_evaluation(proposal, evaluator_id, :safety_check,
          "Protected module: #{inspect(change_proposal.module)} cannot be modified automatically",
          ["Module #{inspect(change_proposal.module)} is on the protected list"],
          ["Submit for manual review instead"]
        )

      # Reject if no change proposal (unstructured)
      is_nil(change_proposal) ->
        reject_evaluation(proposal, evaluator_id, :safety_check,
          "Unstructured proposal: missing ChangeProposal schema",
          ["Proposals must use structured ChangeProposal format"],
          ["Create proposal using ChangeProposal.new/1"]
        )

      # Approve if safety checks pass
      true ->
        approve_evaluation(proposal, evaluator_id, :safety_check,
          "Safety check passed: module #{inspect(change_proposal.module)} is not protected"
        )
    end
  end

  # ============================================================================
  # Policy Compliance Evaluation
  # ============================================================================

  defp check_policy(proposal, evaluator_id) do
    change_proposal = extract_change_proposal(proposal)

    cond do
      # Reject high-impact without sufficient evidence
      change_proposal &&
        change_proposal.estimated_impact == :high &&
        length(change_proposal.evidence) < @min_evidence_for_high_impact ->
        reject_evaluation(proposal, evaluator_id, :policy_compliance,
          "High-impact change requires at least #{@min_evidence_for_high_impact} evidence items",
          ["Only #{length(change_proposal.evidence)} evidence items provided"],
          ["Gather more evidence before resubmitting"]
        )

      # Warn on medium impact
      change_proposal && change_proposal.estimated_impact == :medium ->
        warn_evaluation(proposal, evaluator_id, :policy_compliance,
          "Medium-impact change approved with caution",
          ["Change has medium estimated impact"]
        )

      # Missing change proposal
      is_nil(change_proposal) ->
        reject_evaluation(proposal, evaluator_id, :policy_compliance,
          "Cannot verify policy compliance without structured proposal",
          ["Missing ChangeProposal in proposal context"],
          ["Use structured proposal format"]
        )

      true ->
        approve_evaluation(proposal, evaluator_id, :policy_compliance,
          "Policy compliance check passed"
        )
    end
  end

  # ============================================================================
  # Rollback Verification Evaluation
  # ============================================================================

  defp check_rollback(proposal, evaluator_id) do
    change_proposal = extract_change_proposal(proposal)

    cond do
      # Reject if no rollback plan
      change_proposal && empty_rollback?(change_proposal.rollback_plan) ->
        reject_evaluation(proposal, evaluator_id, :rollback_verification,
          "Missing rollback plan: cannot proceed without recovery strategy",
          ["No rollback plan provided"],
          ["Add a rollback_plan field describing how to revert"]
        )

      # Reject if rollback plan is too vague
      change_proposal && vague_rollback?(change_proposal.rollback_plan) ->
        reject_evaluation(proposal, evaluator_id, :rollback_verification,
          "Rollback plan too vague: needs specific recovery steps",
          ["Rollback plan lacks specific actions"],
          ["Include specific module/version to restore"]
        )

      # Missing change proposal
      is_nil(change_proposal) ->
        reject_evaluation(proposal, evaluator_id, :rollback_verification,
          "Cannot verify rollback plan without structured proposal",
          ["Missing ChangeProposal"],
          ["Use structured proposal format"]
        )

      true ->
        approve_evaluation(proposal, evaluator_id, :rollback_verification,
          "Rollback plan verified: #{String.slice(change_proposal.rollback_plan, 0, 50)}..."
        )
    end
  end

  # ============================================================================
  # Evaluation Builders
  # ============================================================================

  defp approve_evaluation(proposal, evaluator_id, perspective, reasoning) do
    Evaluation.new(%{
      proposal_id: proposal.id,
      evaluator_id: evaluator_id,
      perspective: perspective,
      vote: :approve,
      reasoning: reasoning,
      confidence: 0.95,
      concerns: [],
      recommendations: [],
      risk_score: 0.1,
      benefit_score: 0.8
    })
    |> seal_result()
  end

  defp warn_evaluation(proposal, evaluator_id, perspective, reasoning, concerns) do
    Evaluation.new(%{
      proposal_id: proposal.id,
      evaluator_id: evaluator_id,
      perspective: perspective,
      vote: :approve,
      reasoning: reasoning,
      confidence: 0.7,
      concerns: concerns,
      recommendations: ["Monitor closely after deployment"],
      risk_score: 0.4,
      benefit_score: 0.6
    })
    |> seal_result()
  end

  defp reject_evaluation(proposal, evaluator_id, perspective, reasoning, concerns, recommendations) do
    Evaluation.new(%{
      proposal_id: proposal.id,
      evaluator_id: evaluator_id,
      perspective: perspective,
      vote: :reject,
      reasoning: reasoning,
      confidence: 0.95,
      concerns: concerns,
      recommendations: recommendations,
      risk_score: 0.9,
      benefit_score: 0.1
    })
    |> seal_result()
  end

  defp unsupported_perspective(proposal, perspective, evaluator_id) do
    Evaluation.new(%{
      proposal_id: proposal.id,
      evaluator_id: evaluator_id,
      perspective: perspective,
      vote: :abstain,
      reasoning: "Unsupported perspective: #{perspective}",
      confidence: 0.0,
      concerns: ["Unknown perspective"],
      recommendations: ["Use safety_check, policy_compliance, or rollback_verification"],
      risk_score: 0.5,
      benefit_score: 0.0
    })
    |> seal_result()
  end

  defp seal_result({:ok, evaluation}), do: {:ok, Evaluation.seal(evaluation)}
  defp seal_result(error), do: error

  # ============================================================================
  # Helpers
  # ============================================================================

  defp extract_change_proposal(%Proposal{context: context}) when is_map(context) do
    case Map.get(context, :change_proposal) do
      %ChangeProposal{} = cp -> cp
      _ -> nil
    end
  end

  defp extract_change_proposal(_), do: nil

  defp protected_namespace?(module) do
    module_string = to_string(module)

    Enum.any?([
      String.starts_with?(module_string, "Elixir.Arbor.Security."),
      String.starts_with?(module_string, "Elixir.Arbor.Consensus."),
      String.starts_with?(module_string, "Elixir.Arbor.Persistence.")
    ])
  end

  defp empty_rollback?(nil), do: true
  defp empty_rollback?(plan) when is_binary(plan), do: String.trim(plan) == ""
  defp empty_rollback?(_), do: true

  defp vague_rollback?(plan) when is_binary(plan) do
    plan_lower = String.downcase(plan)

    # Check for vague plans
    vague_phrases = ["tbd", "to be determined", "figure out later", "none", "n/a"]

    Enum.any?(vague_phrases, &String.contains?(plan_lower, &1)) or
      String.length(String.trim(plan)) < 10
  end

  defp vague_rollback?(_), do: true

  defp generate_evaluator_id(perspective) do
    "eval_demo_#{perspective}_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  end

  # ============================================================================
  # LLM System Prompts
  # ============================================================================

  defp security_system_prompt do
    """
    You are a security evaluator for automated code changes in the Arbor system.

    Your role is to identify potential security vulnerabilities in proposed code changes.

    Focus on:
    - Command injection risks
    - Path traversal vulnerabilities
    - Unsafe atom creation
    - Process isolation violations
    - Capability/permission bypasses

    Vote :approve if the code appears safe.
    Vote :reject if you identify security concerns.

    Always explain your reasoning clearly.
    """
  end

  defp performance_system_prompt do
    """
    You are a performance evaluator for automated code changes in the Arbor system.

    Your role is to identify potential performance issues in proposed code changes.

    Focus on:
    - Memory leaks or unbounded growth
    - Blocking operations in GenServer callbacks
    - N+1 query patterns
    - Unbounded recursion
    - Large message passing between processes

    Vote :approve if the code appears performant.
    Vote :reject if you identify performance concerns.

    Always explain your reasoning clearly.
    """
  end
end
