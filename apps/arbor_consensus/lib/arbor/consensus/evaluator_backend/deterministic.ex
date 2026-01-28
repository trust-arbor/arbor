defmodule Arbor.Consensus.EvaluatorBackend.Deterministic do
  @moduledoc """
  Deterministic evaluator backend that runs actual shell commands.

  Unlike the `RuleBased` backend which analyzes code heuristically, this backend
  executes real commands (mix test, mix credo, etc.) and votes based on pass/fail.

  ## Perspectives

  - `:mix_test` — Runs `mix test`, approves if exit code is 0
  - `:mix_credo` — Runs `mix credo --strict`, approves if exit code is 0
  - `:mix_compile` — Runs `mix compile --warnings-as-errors`, approves if exit code is 0
  - `:mix_format_check` — Runs `mix format --check-formatted`, approves if exit code is 0
  - `:mix_dialyzer` — Runs `mix dialyzer`, approves if exit code is 0

  ## Configuration

  The proposal metadata should include:

      %{
        project_path: "/path/to/elixir/project",  # required for deterministic evaluation
        test_paths: ["test/specific_test.exs"],   # optional, run specific tests
        env: %{"MIX_ENV" => "test"}               # optional env vars
      }

  ## Example

      Arbor.Consensus.submit(proposal,
        evaluator_backend: Arbor.Consensus.EvaluatorBackend.Deterministic,
        perspectives: [:mix_test, :mix_credo]
      )
  """

  @behaviour Arbor.Consensus.EvaluatorBackend

  alias Arbor.Consensus.Config
  alias Arbor.Contracts.Consensus.{Evaluation, Proposal}

  require Logger

  @supported_perspectives [
    :mix_test,
    :mix_credo,
    :mix_compile,
    :mix_format_check,
    :mix_dialyzer
  ]

  @impl true
  @spec evaluate(Proposal.t(), atom(), keyword()) :: {:ok, Evaluation.t()} | {:error, term()}
  def evaluate(%Proposal{} = proposal, perspective, opts \\ []) do
    evaluator_id = Keyword.get(opts, :evaluator_id, generate_evaluator_id(perspective))

    if perspective in @supported_perspectives do
      do_evaluate(proposal, perspective, evaluator_id, opts)
    else
      unsupported_perspective(proposal, perspective, evaluator_id)
    end
  end

  @doc """
  List supported perspectives for this backend.
  """
  @spec supported_perspectives() :: [atom()]
  def supported_perspectives, do: @supported_perspectives

  # ============================================================================
  # Evaluation Logic
  # ============================================================================

  defp do_evaluate(proposal, perspective, evaluator_id, opts) do
    project_path = get_project_path(proposal, opts)

    if is_nil(project_path) do
      missing_project_path(proposal, perspective, evaluator_id)
    else
      run_command(proposal, perspective, evaluator_id, project_path, opts)
    end
  end

  defp run_command(proposal, perspective, evaluator_id, project_path, opts) do
    command = build_command(perspective, proposal, opts)
    timeout = Keyword.get(opts, :timeout, Config.deterministic_evaluator_timeout())
    sandbox = Keyword.get(opts, :sandbox, Config.deterministic_evaluator_sandbox())
    env = get_env(proposal, perspective, opts)

    shell_opts = [
      timeout: timeout,
      sandbox: sandbox,
      cwd: project_path,
      env: env
    ]

    Logger.debug(
      "Deterministic evaluator running: #{command} in #{project_path} (timeout: #{timeout}ms)"
    )

    case Arbor.Shell.execute(command, shell_opts) do
      {:ok, result} ->
        build_evaluation_from_result(proposal, perspective, evaluator_id, result, command)

      {:error, reason} ->
        build_error_evaluation(proposal, perspective, evaluator_id, reason, command)
    end
  end

  # ============================================================================
  # Command Building
  # ============================================================================

  defp build_command(:mix_test, proposal, opts) do
    test_paths = get_test_paths(proposal, opts)

    if test_paths != [] do
      "mix test #{Enum.join(test_paths, " ")}"
    else
      "mix test"
    end
  end

  defp build_command(:mix_credo, _proposal, _opts) do
    "mix credo --strict"
  end

  defp build_command(:mix_compile, _proposal, _opts) do
    "mix compile --warnings-as-errors"
  end

  defp build_command(:mix_format_check, _proposal, _opts) do
    "mix format --check-formatted"
  end

  defp build_command(:mix_dialyzer, _proposal, _opts) do
    "mix dialyzer"
  end

  # ============================================================================
  # Result Processing
  # ============================================================================

  defp build_evaluation_from_result(proposal, perspective, evaluator_id, result, command) do
    passed = result.exit_code == 0
    vote = if passed, do: :approve, else: :reject
    confidence = if result.timed_out, do: 0.3, else: 0.95

    concerns = extract_concerns(result, perspective, passed)
    recommendations = build_recommendations(perspective, passed, result)

    reasoning = build_reasoning(perspective, result, command)

    case Evaluation.new(%{
           proposal_id: proposal.id,
           evaluator_id: evaluator_id,
           perspective: perspective,
           vote: vote,
           reasoning: reasoning,
           confidence: confidence,
           concerns: concerns,
           recommendations: recommendations,
           risk_score: if(passed, do: 0.1, else: 0.9),
           benefit_score: if(passed, do: 0.9, else: 0.1)
         }) do
      {:ok, evaluation} ->
        {:ok, Evaluation.seal(evaluation)}

      {:error, _} = error ->
        error
    end
  end

  defp build_error_evaluation(proposal, perspective, evaluator_id, reason, command) do
    case Evaluation.new(%{
           proposal_id: proposal.id,
           evaluator_id: evaluator_id,
           perspective: perspective,
           vote: :reject,
           reasoning: "Failed to execute #{command}: #{inspect(reason)}",
           confidence: 0.5,
           concerns: ["Command execution failed: #{inspect(reason)}"],
           recommendations: ["Verify project path and command availability"],
           risk_score: 0.8,
           benefit_score: 0.0
         }) do
      {:ok, evaluation} ->
        {:ok, Evaluation.seal(evaluation)}

      {:error, _} = error ->
        error
    end
  end

  defp build_reasoning(perspective, result, command) do
    status =
      cond do
        result.timed_out -> "timed out"
        result.exit_code == 0 -> "passed"
        true -> "failed with exit code #{result.exit_code}"
      end

    duration_str = "#{result.duration_ms}ms"

    base = "#{perspective_name(perspective)} #{status} (#{duration_str})"

    if result.exit_code != 0 and result.stderr != "" do
      error_snippet = String.slice(result.stderr, 0, 200)
      "#{base}. Command: #{command}. Error: #{error_snippet}"
    else
      "#{base}. Command: #{command}"
    end
  end

  defp perspective_name(:mix_test), do: "Mix test"
  defp perspective_name(:mix_credo), do: "Mix credo --strict"
  defp perspective_name(:mix_compile), do: "Mix compile --warnings-as-errors"
  defp perspective_name(:mix_format_check), do: "Mix format check"
  defp perspective_name(:mix_dialyzer), do: "Mix dialyzer"
  defp perspective_name(other), do: "#{other}"

  defp extract_concerns(result, _perspective, true = _passed) do
    # Even on pass, check for warnings in output
    output = result.stdout <> result.stderr

    []
    |> maybe_add_concern(
      String.contains?(output, "warning:"),
      "Warnings present in output"
    )
    |> maybe_add_concern(
      String.contains?(output, "deprecated"),
      "Deprecated function usage detected"
    )
  end

  defp extract_concerns(result, perspective, false = _passed) do
    output = result.stdout <> result.stderr

    base_concerns = ["#{perspective_name(perspective)} failed"]

    base_concerns
    |> maybe_add_concern(
      String.contains?(output, "** ("),
      "Exception raised during execution"
    )
    |> maybe_add_concern(
      String.contains?(output, "error:"),
      "Compilation or analysis errors found"
    )
    |> maybe_add_concern(
      result.timed_out,
      "Command timed out - may indicate infinite loop or slow tests"
    )
  end

  defp maybe_add_concern(concerns, true, message), do: [message | concerns]
  defp maybe_add_concern(concerns, false, _message), do: concerns

  defp build_recommendations(:mix_test, false, _result) do
    ["Fix failing tests before proceeding", "Run `mix test` locally to debug"]
  end

  defp build_recommendations(:mix_credo, false, _result) do
    ["Address credo warnings", "Run `mix credo --strict` locally for details"]
  end

  defp build_recommendations(:mix_compile, false, _result) do
    ["Fix compilation warnings", "Run `mix compile --warnings-as-errors` locally"]
  end

  defp build_recommendations(:mix_format_check, false, _result) do
    ["Run `mix format` to fix formatting issues"]
  end

  defp build_recommendations(:mix_dialyzer, false, _result) do
    ["Address dialyzer warnings", "Run `mix dialyzer` locally for details"]
  end

  defp build_recommendations(_perspective, true, _result), do: []

  # ============================================================================
  # Error Cases
  # ============================================================================

  defp unsupported_perspective(proposal, perspective, evaluator_id) do
    supported = Enum.join(@supported_perspectives, ", ")

    case Evaluation.new(%{
           proposal_id: proposal.id,
           evaluator_id: evaluator_id,
           perspective: perspective,
           vote: :abstain,
           reasoning:
             "Unsupported perspective: #{perspective}. " <>
               "Deterministic backend supports: #{supported}",
           confidence: 0.0,
           concerns: ["Unsupported evaluation perspective"],
           recommendations: ["Use a supported perspective or the RuleBased backend"],
           risk_score: 0.5,
           benefit_score: 0.0
         }) do
      {:ok, evaluation} ->
        {:ok, Evaluation.seal(evaluation)}

      {:error, _} = error ->
        error
    end
  end

  defp missing_project_path(proposal, perspective, evaluator_id) do
    case Evaluation.new(%{
           proposal_id: proposal.id,
           evaluator_id: evaluator_id,
           perspective: perspective,
           vote: :abstain,
           reasoning:
             "Cannot run #{perspective}: no project_path in proposal metadata. " <>
               "Deterministic evaluation requires a valid Elixir project path.",
           confidence: 0.0,
           concerns: ["Missing project_path in proposal metadata"],
           recommendations: [
             "Include project_path in proposal metadata",
             "Use RuleBased backend for proposals without project context"
           ],
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

  defp get_project_path(proposal, opts) do
    Keyword.get(opts, :project_path) ||
      get_in(proposal.metadata, [:project_path]) ||
      Config.deterministic_evaluator_default_cwd()
  end

  defp get_test_paths(proposal, opts) do
    Keyword.get(opts, :test_paths, []) ++
      (get_in(proposal.metadata, [:test_paths]) || [])
  end

  defp get_env(proposal, perspective, opts) do
    base_env = Keyword.get(opts, :env, %{})
    proposal_env = get_in(proposal.metadata, [:env]) || %{}

    # Set MIX_ENV appropriately for each perspective
    mix_env =
      case perspective do
        :mix_test -> "test"
        :mix_dialyzer -> "dev"
        _ -> "dev"
      end

    Map.merge(proposal_env, base_env)
    |> Map.put_new("MIX_ENV", mix_env)
  end

  defp generate_evaluator_id(perspective) do
    "eval_det_#{perspective}_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  end
end
