defmodule Arbor.Consensus.EvaluatorBackend.RuleBased do
  @moduledoc """
  Default rule-based evaluator backend.

  Evaluates proposals using heuristic rules for each perspective.
  No LLM or external service required — pure code analysis.

  ## Perspectives

  - `:security` — Scans for dangerous modules (System, File, eval, :os)
  - `:stability` — Checks for process spawning, GenServer/Supervisor changes
  - `:capability` — Assesses functionality impact based on change type
  - `:adversarial` — Red team analysis for bypass/override/skip patterns
  - `:resource` — Efficiency analysis (list traversals, recursion, code size)
  - `:emergence` — Novel behavior detection (agents, learning, adaptation)
  - `:random` — Intentional randomness to prevent groupthink
  - `:test_runner` — Test quality and coverage assessment
  - `:code_review` — Code quality and standards evaluation
  - `:human` — Always abstains, signals need for human review
  """

  @behaviour Arbor.Consensus.EvaluatorBackend
  @behaviour Arbor.Contracts.Consensus.Evaluator

  alias Arbor.Contracts.Consensus.{Evaluation, Proposal}

  require Logger

  @supported_perspectives [
    :security,
    :stability,
    :capability,
    :adversarial,
    :resource,
    :emergence,
    :random,
    :test_runner,
    :code_review,
    :human
  ]

  # ============================================================================
  # Evaluator Behaviour Callbacks
  # ============================================================================

  @doc """
  Unique name identifying this evaluator.
  """
  @impl Arbor.Contracts.Consensus.Evaluator
  @spec name() :: atom()
  def name, do: :rule_based

  @doc """
  Perspectives this evaluator can assess from.
  """
  @impl Arbor.Contracts.Consensus.Evaluator
  @spec perspectives() :: [atom()]
  def perspectives, do: @supported_perspectives

  @doc """
  Strategy this evaluator uses.
  """
  @impl Arbor.Contracts.Consensus.Evaluator
  @spec strategy() :: :rule_based
  def strategy, do: :rule_based

  # ============================================================================
  # Evaluate Callback (shared by both behaviours)
  # ============================================================================

  # Note: Both EvaluatorBackend and Evaluator define evaluate/3. The @impl is
  # for the Evaluator behaviour since EvaluatorBackend is being deprecated.
  @impl Arbor.Contracts.Consensus.Evaluator
  @spec evaluate(Proposal.t(), atom(), keyword()) :: {:ok, Evaluation.t()} | {:error, term()}
  def evaluate(%Proposal{} = proposal, perspective, opts \\ []) do
    evaluator_id = Keyword.get(opts, :evaluator_id, generate_evaluator_id(perspective))
    assessment = assess(perspective, proposal)

    case Evaluation.new(%{
           proposal_id: proposal.id,
           evaluator_id: evaluator_id,
           perspective: perspective,
           vote: assessment.vote,
           reasoning: assessment.reasoning,
           confidence: assessment.confidence,
           concerns: assessment.concerns,
           recommendations: assessment.recommendations,
           risk_score: assessment.risk_score,
           benefit_score: assessment.benefit_score
         }) do
      {:ok, evaluation} ->
        {:ok, Evaluation.seal(evaluation)}

      {:error, _} = error ->
        error
    end
  end

  # ============================================================================
  # Perspective Assessments
  # ============================================================================

  defp assess(:security, proposal) do
    concerns = security_concerns(proposal)
    risk = calculate_security_risk(proposal, concerns)

    %{
      vote: if(risk < 0.5, do: :approve, else: :reject),
      reasoning: security_reasoning(proposal, concerns),
      confidence: 0.8,
      concerns: concerns,
      recommendations: Enum.map(concerns, &"Review and address: #{&1}"),
      risk_score: risk,
      benefit_score: 0.3
    }
  end

  defp assess(:stability, proposal) do
    concerns = stability_concerns(proposal)
    risk = calculate_stability_risk(proposal, concerns)

    %{
      vote: if(risk < 0.6, do: :approve, else: :reject),
      reasoning: stability_reasoning(proposal, concerns),
      confidence: 0.75,
      concerns: concerns,
      recommendations:
        if(Enum.empty?(concerns),
          do: [],
          else: ["Consider adding rollback mechanism", "Add monitoring for affected components"]
        ),
      risk_score: risk,
      benefit_score: 0.4
    }
  end

  defp assess(:capability, proposal) do
    benefit = calculate_capability_benefit(proposal)
    concerns = capability_concerns(proposal)

    %{
      vote: if(benefit > 0.4, do: :approve, else: :reject),
      reasoning:
        "Capability assessment for #{proposal.topic}: " <>
          "Estimated benefit score #{Float.round(benefit, 2)}.",
      confidence: 0.7,
      concerns: concerns,
      recommendations: [],
      risk_score: 0.3,
      benefit_score: benefit
    }
  end

  defp assess(:adversarial, proposal) do
    exploits = find_potential_exploits(proposal)
    risk = min(length(exploits) * 0.2, 1.0)

    %{
      vote: if(risk < 0.6, do: :approve, else: :reject),
      reasoning: adversarial_reasoning(proposal, exploits),
      confidence: 0.85,
      concerns: exploits,
      recommendations:
        if(Enum.empty?(exploits),
          do: [],
          else: ["Conduct manual security review", "Test in isolated environment first"]
        ),
      risk_score: risk,
      benefit_score: 0.2
    }
  end

  defp assess(:resource, proposal) do
    impact = estimate_resource_impact(proposal)
    concerns = resource_concerns(proposal)

    %{
      vote: if(impact.efficiency > 0.5, do: :approve, else: :reject),
      reasoning:
        "Resource analysis: Estimated #{Float.round(impact.efficiency * 100, 1)}% efficiency. " <>
          "#{impact.lines} lines of code, #{impact.complexity} complexity.",
      confidence: 0.65,
      concerns: concerns,
      recommendations: [],
      risk_score: 1.0 - impact.efficiency,
      benefit_score: impact.efficiency
    }
  end

  defp assess(:emergence, proposal) do
    potential = calculate_emergence_potential(proposal)
    concerns = emergence_concerns(proposal)

    %{
      vote: if(potential > 0.3, do: :approve, else: :abstain),
      reasoning: emergence_reasoning(proposal, potential),
      confidence: 0.5,
      concerns: concerns,
      recommendations: emergence_recommendations(proposal),
      risk_score: 0.4,
      benefit_score: potential
    }
  end

  defp assess(:random, proposal) do
    random_factor = :rand.uniform()
    concerns = random_concerns()

    vote =
      cond do
        random_factor > 0.7 -> :approve
        random_factor < 0.3 -> :reject
        true -> :abstain
      end

    %{
      vote: vote,
      reasoning: random_reasoning(proposal, random_factor),
      confidence: 0.4 + random_factor * 0.3,
      concerns: concerns,
      recommendations: [],
      risk_score: :rand.uniform(),
      benefit_score: :rand.uniform()
    }
  end

  defp assess(:test_runner, proposal) do
    test_quality = assess_test_quality(proposal)
    coverage = estimate_test_coverage(proposal)
    concerns = test_runner_concerns(proposal)

    %{
      vote: if(test_quality > 0.6 and coverage > 0.7, do: :approve, else: :reject),
      reasoning:
        "Test Runner analysis: Quality score #{Float.round(test_quality, 2)}, " <>
          "Coverage estimate #{Float.round(coverage, 2)}.",
      confidence: 0.75,
      concerns: concerns,
      recommendations: test_runner_recommendations(concerns),
      risk_score: 1.0 - test_quality,
      benefit_score: min(test_quality, coverage)
    }
  end

  defp assess(:code_review, proposal) do
    quality_score = assess_code_quality(proposal)
    concerns = code_review_concerns(proposal)

    %{
      vote: if(quality_score > 0.7, do: :approve, else: :reject),
      reasoning:
        "Code Review analysis: Quality score #{Float.round(quality_score, 2)}. " <>
          "Proposal #{if quality_score > 0.7, do: "meets", else: "fails"} code quality standards.",
      confidence: 0.8,
      concerns: concerns,
      recommendations: code_review_recommendations(concerns),
      risk_score: 1.0 - quality_score,
      benefit_score: quality_score
    }
  end

  defp assess(:human, _proposal) do
    %{
      vote: :abstain,
      reasoning: "Human review required. Council decision pending human evaluation.",
      confidence: 1.0,
      concerns: ["Requires human oversight"],
      recommendations: ["Escalate to human reviewer"],
      risk_score: 0.0,
      benefit_score: 0.0
    }
  end

  # Fallback for unknown perspectives
  defp assess(perspective, _proposal) do
    %{
      vote: :abstain,
      reasoning: "Unknown perspective: #{perspective}. Abstaining.",
      confidence: 0.0,
      concerns: ["Unrecognized evaluation perspective"],
      recommendations: [],
      risk_score: 0.5,
      benefit_score: 0.5
    }
  end

  # ============================================================================
  # Context Accessors (for migrated fields)
  # ============================================================================

  defp get_new_code(proposal) do
    Map.get(proposal.context, :new_code, "")
  end

  defp get_target_module(proposal) do
    Map.get(proposal.context, :target_module)
  end

  # ============================================================================
  # Security Analysis
  # ============================================================================

  defp security_concerns(proposal) do
    code = get_new_code(proposal)

    []
    |> check_pattern(code, "System", "Uses System module which could allow command execution")
    |> check_pattern(code, "File", "Uses File module which could allow filesystem access")
    |> check_pattern(code, "eval", "Uses eval which could allow code injection")
    |> check_pattern(code, ":os", "Directly uses :os module")
  end

  defp calculate_security_risk(proposal, concerns) do
    base_risk = length(concerns) * 0.25
    layer_multiplier = (5 - proposal.target_layer) * 0.1
    min(base_risk + layer_multiplier, 1.0)
  end

  defp security_reasoning(proposal, concerns) do
    if Enum.empty?(concerns) do
      "No obvious security concerns detected in proposal #{proposal.id}. " <>
        "Code appears to use safe modules only."
    else
      layer_msg =
        if proposal.target_layer <= 2,
          do: "is high-risk core infrastructure.",
          else: "is relatively isolated."

      "Security concerns detected: #{Enum.join(concerns, "; ")}. " <>
        "Target layer #{proposal.target_layer} #{layer_msg}"
    end
  end

  # ============================================================================
  # Stability Analysis
  # ============================================================================

  defp stability_concerns(proposal) do
    code = get_new_code(proposal)

    []
    |> check_pattern(code, "spawn", "Spawns new processes which could affect system stability")
    |> check_pattern_pair(
      code,
      "GenServer",
      "handle_",
      "Modifies GenServer behavior which is critical infrastructure"
    )
    |> check_pattern(
      code,
      "Supervisor",
      "Modifies supervision tree which could cause cascading failures"
    )
  end

  defp calculate_stability_risk(proposal, concerns) do
    base_risk = length(concerns) * 0.2
    layer_bonus = proposal.target_layer * 0.05
    max(base_risk - layer_bonus, 0.1)
  end

  defp stability_reasoning(proposal, concerns) do
    if Enum.empty?(concerns) do
      "Proposal appears stable. No critical infrastructure modifications detected."
    else
      "Stability concerns: #{length(concerns)} potential issues found. " <>
        "Layer #{proposal.target_layer} modification requires careful consideration."
    end
  end

  # ============================================================================
  # Capability Analysis
  # ============================================================================

  defp capability_concerns(proposal) do
    case proposal.topic do
      :capability_change -> ["Direct capability modification - verify authorization flow"]
      :governance_change -> ["Governance change affects system-wide behavior"]
      _ -> []
    end
  end

  defp calculate_capability_benefit(proposal) do
    base_benefit =
      case proposal.topic do
        :code_modification -> 0.5
        :capability_change -> 0.6
        :configuration_change -> 0.4
        _ -> 0.3
      end

    complexity_factor = min(String.length(proposal.description) / 200, 1.0) * 0.2
    base_benefit + complexity_factor
  end

  # ============================================================================
  # Adversarial Analysis
  # ============================================================================

  defp find_potential_exploits(proposal) do
    code = get_new_code(proposal)

    []
    |> check_pattern(
      code,
      "bypass",
      "Code contains 'bypass' which may indicate security circumvention"
    )
    |> check_pattern(
      code,
      "override",
      "Code contains 'override' which could disable protections"
    )
    |> check_pattern_pair(code, "skip", "check", "Code may skip security checks")
  end

  defp adversarial_reasoning(proposal, exploits) do
    if Enum.empty?(exploits) do
      "Red team analysis: No obvious exploitation vectors found in proposal #{proposal.id}."
    else
      "Red team analysis found #{length(exploits)} potential exploitation vectors. " <>
        "Manual review recommended before approval."
    end
  end

  # ============================================================================
  # Resource Analysis
  # ============================================================================

  defp resource_concerns(proposal) do
    code = get_new_code(proposal)

    []
    |> check_pattern_pair(
      code,
      "Enum.map",
      "Enum.filter",
      "Multiple list traversals could be combined"
    )
    |> check_pattern_any(
      code,
      ["recursion", "recursive"],
      "Recursive code - verify tail call optimization"
    )
  end

  defp estimate_resource_impact(proposal) do
    code = get_new_code(proposal)
    lines = code |> String.split("\n") |> length()
    has_complex = String.contains?(code, ["Enum.reduce", "recursion", "spawn"])

    efficiency =
      cond do
        lines > 100 -> 0.3
        has_complex -> 0.5
        lines < 20 -> 0.9
        true -> 0.7
      end

    %{efficiency: efficiency, lines: lines, complexity: if(has_complex, do: :high, else: :low)}
  end

  # ============================================================================
  # Emergence Analysis
  # ============================================================================

  @novel_patterns [
    "Agent",
    "autonomous",
    "learning",
    "adapt",
    "evolve",
    "GenServer",
    "supervisor",
    "registry",
    "pubsub"
  ]

  defp calculate_emergence_potential(proposal) do
    code = get_new_code(proposal)
    matches = Enum.count(@novel_patterns, &String.contains?(code, &1))
    min(matches / length(@novel_patterns), 1.0)
  end

  defp emergence_concerns(proposal) do
    code = get_new_code(proposal)

    []
    |> then(fn concerns ->
      if String.contains?(code, ["loop", "while", "recursive"]) and
           not String.contains?(code, ["timeout", "max_iterations"]) do
        ["Potential for infinite loops or runaway processes" | concerns]
      else
        concerns
      end
    end)
    |> then(fn concerns ->
      if String.contains?(code, ["Agent", "Registry"]) and
           not String.contains?(code, ["supervisor"]) do
        ["Autonomous agents without supervision could become orphaned" | concerns]
      else
        concerns
      end
    end)
  end

  defp emergence_reasoning(proposal, potential) do
    pct = Float.round(potential * 100, 1)

    if potential > 0.3 do
      "Emergence analysis: High potential for novel behavior (#{pct}%). " <>
        "Proposal #{proposal.id} shows signs of autonomous or adaptive systems."
    else
      "Emergence analysis: Low emergence potential (#{pct}%). " <>
        "Proposal #{proposal.id} appears to be standard implementation."
    end
  end

  defp emergence_recommendations(proposal) do
    code = get_new_code(proposal)

    if String.contains?(code, ["Agent", "autonomous"]) do
      ["Monitor for emergent behaviors", "Ensure proper supervision hierarchy"]
    else
      []
    end
  end

  # ============================================================================
  # Random Analysis
  # ============================================================================

  defp random_concerns do
    all = [
      "Change complexity warrants additional review",
      "Consider edge cases not covered in proposal",
      "Documentation may need updating",
      "Test coverage should be verified"
    ]

    count = :rand.uniform(3) - 1
    Enum.take_random(all, count)
  end

  defp random_reasoning(proposal, factor) do
    adjective =
      cond do
        factor > 0.7 -> "favorable"
        factor < 0.3 -> "unfavorable"
        true -> "neutral"
      end

    "Random perspective assessment: #{adjective} impression of proposal #{proposal.id}. " <>
      "This perspective provides intentional unpredictability to prevent groupthink."
  end

  # ============================================================================
  # Test Runner Analysis
  # ============================================================================

  defp assess_test_quality(proposal) do
    code = get_new_code(proposal)

    has_tests = String.contains?(code, ["ExUnit", "describe", "test", "@tag"])
    has_assertions = String.contains?(code, ["assert", "refute", "assert_receive"])

    test_file =
      String.contains?(code, "_test.exs") or
        String.contains?(to_string(get_target_module(proposal)), "_test")

    score = 0.0
    score = if test_file, do: score + 0.4, else: score
    score = if has_tests, do: score + 0.3, else: score
    score = if has_assertions, do: score + 0.3, else: score
    min(score, 1.0)
  end

  defp estimate_test_coverage(proposal) do
    code = get_new_code(proposal)
    metadata = proposal.metadata || %{}

    case metadata[:test_coverage] do
      coverage when is_number(coverage) ->
        coverage

      _ ->
        lines = String.split(code, "\n")
        test_lines = Enum.count(lines, &String.contains?(&1, ["assert", "refute", "test"]))
        min(test_lines / max(length(lines), 1), 1.0)
    end
  end

  defp test_runner_concerns(proposal) do
    code = get_new_code(proposal)

    []
    |> then(fn c ->
      if String.contains?(code, ["assert", "refute"]), do: c, else: ["No assertions found" | c]
    end)
    |> then(fn c ->
      if String.contains?(code, ["test", "describe"]) or String.contains?(code, "_test.exs"),
        do: c,
        else: ["No test structure detected" | c]
    end)
    |> then(fn c ->
      if String.contains?(code, ["rescue", "catch"]) and
           not String.contains?(code, ["assert_raise", "assert_receive"]) do
        ["Exception handling present but not tested" | c]
      else
        c
      end
    end)
  end

  defp test_runner_recommendations(concerns) do
    Enum.map(concerns, fn
      "No assertions found" <> _ -> "Add proper assertions to validate behavior"
      "No test structure" <> _ -> "Implement proper test structure with describe/test blocks"
      "Exception handling" <> _ -> "Add tests for error conditions and exception handling"
      _ -> "Address test quality concerns"
    end)
  end

  # ============================================================================
  # Code Review Analysis
  # ============================================================================

  defp assess_code_quality(proposal) do
    code = get_new_code(proposal)

    1.0
    |> deduct_if(
      String.contains?(code, ["IO.puts", "IO.inspect"]) and
        not String.contains?(code, ["test", "_test.exs"]),
      0.2
    )
    |> deduct_if(String.length(code) > 2000, 0.1)
    |> deduct_if(String.contains?(code, ["# TODO", "# FIXME", "# HACK"]), 0.15)
    |> deduct_if(not String.contains?(code, ["@spec", "@doc"]), 0.1)
    |> deduct_if(
      String.contains?(code, ["rescue", "catch"]) and not String.contains?(code, ["Logger"]),
      0.1
    )
    |> bonus_if(String.contains?(code, ["@moduledoc", "@doc"]), 0.1)
    |> bonus_if(String.contains?(code, ["with"]), 0.05)
    |> max(0.0)
  end

  defp code_review_concerns(proposal) do
    code = get_new_code(proposal)

    []
    |> then(fn c ->
      if String.contains?(code, ["IO.puts", "IO.inspect"]) and
           not String.contains?(code, ["test", "_test.exs"]) do
        ["Debug output left in production code" | c]
      else
        c
      end
    end)
    |> then(fn c ->
      if String.contains?(code, ["# TODO", "# FIXME", "# HACK"]),
        do: ["Technical debt markers present" | c],
        else: c
    end)
    |> then(fn c ->
      if String.contains?(code, ["@doc"]), do: c, else: ["Missing documentation" | c]
    end)
    |> then(fn c ->
      if String.length(code) > 2000,
        do: ["Code is too long, consider breaking into smaller functions" | c],
        else: c
    end)
    |> then(fn c ->
      if String.contains?(code, ["rescue", "catch"]) and not String.contains?(code, ["Logger"]) do
        ["Exception handling without proper logging" | c]
      else
        c
      end
    end)
  end

  defp code_review_recommendations(concerns) do
    Enum.map(concerns, fn
      "Debug output" <> _ -> "Remove debug output before merging"
      "Technical debt" <> _ -> "Address TODO/FIXME items or create follow-up issues"
      "Missing documentation" -> "Add proper @doc and @spec annotations"
      "Code is too long" <> _ -> "Refactor into smaller, more focused functions"
      "Exception handling" <> _ -> "Add appropriate logging for error conditions"
      _ -> "Address code quality concerns"
    end)
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp check_pattern(concerns, code, pattern, message) do
    if String.contains?(code, pattern), do: [message | concerns], else: concerns
  end

  defp check_pattern_pair(concerns, code, pattern1, pattern2, message) do
    if String.contains?(code, pattern1) and String.contains?(code, pattern2) do
      [message | concerns]
    else
      concerns
    end
  end

  defp check_pattern_any(concerns, code, patterns, message) do
    if Enum.any?(patterns, &String.contains?(code, &1)) do
      [message | concerns]
    else
      concerns
    end
  end

  defp deduct_if(score, true, amount), do: score - amount
  defp deduct_if(score, false, _amount), do: score

  defp bonus_if(score, true, amount), do: min(score + amount, 1.0)
  defp bonus_if(score, false, _amount), do: score

  defp generate_evaluator_id(perspective) do
    "eval_#{perspective}_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  end
end
