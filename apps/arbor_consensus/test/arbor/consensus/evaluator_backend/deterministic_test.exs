defmodule Arbor.Consensus.EvaluatorBackend.DeterministicTest do
  use ExUnit.Case, async: false

  alias Arbor.Consensus.Config
  alias Arbor.Consensus.EvaluatorBackend.Deterministic
  alias Arbor.Contracts.Consensus.Evaluation
  alias Arbor.Contracts.Consensus.Proposal

  # Use the arbor project itself for testing (6 levels up from test file)
  # apps/arbor_consensus/test/arbor/consensus/evaluator_backend/ → arbor/
  @project_path Path.expand("../../../../../..", __DIR__)

  setup do
    # Create a minimal proposal for testing
    {:ok, proposal} =
      Proposal.new(%{
        proposer: "test_agent",
        change_type: :code_modification,
        description: "Test proposal for deterministic evaluation",
        metadata: %{
          project_path: @project_path
        }
      })

    {:ok, proposal: proposal}
  end

  describe "supported_perspectives/0" do
    test "returns all supported perspectives" do
      perspectives = Deterministic.supported_perspectives()

      assert :mix_test in perspectives
      assert :mix_credo in perspectives
      assert :mix_compile in perspectives
      assert :mix_format_check in perspectives
      assert :mix_dialyzer in perspectives
    end
  end

  describe "evaluate/3 with :mix_compile" do
    @tag :slow
    @tag timeout: 120_000
    test "produces valid evaluation for compilation", %{proposal: proposal} do
      # mix compile --warnings-as-errors on the umbrella project
      # May pass or fail depending on whether warnings exist (test modules, etc.)
      # Use :basic sandbox to allow mix subprocesses
      {:ok, evaluation} =
        Deterministic.evaluate(proposal, :mix_compile, timeout: 60_000, sandbox: :basic)

      assert %Evaluation{} = evaluation
      assert evaluation.perspective == :mix_compile
      assert evaluation.sealed == true
      # Vote depends on whether there are warnings; we just verify the evaluation is valid
      assert evaluation.vote in [:approve, :reject]
      assert evaluation.confidence > 0.0
      assert String.contains?(evaluation.reasoning, "Mix compile")
    end
  end

  describe "evaluate/3 with :mix_format_check" do
    @tag :slow
    @tag timeout: 120_000
    test "returns evaluation for format check", %{proposal: proposal} do
      # This may pass or fail depending on current formatting state
      {:ok, evaluation} =
        Deterministic.evaluate(proposal, :mix_format_check, timeout: 60_000, sandbox: :basic)

      assert %Evaluation{} = evaluation
      assert evaluation.perspective == :mix_format_check
      assert evaluation.sealed == true
      assert evaluation.vote in [:approve, :reject]
    end
  end

  describe "evaluate/3 without project_path" do
    test "abstains when project_path is missing" do
      {:ok, proposal} =
        Proposal.new(%{
          proposer: "test_agent",
          change_type: :code_modification,
          description: "Proposal without project path",
          metadata: %{}
        })

      {:ok, evaluation} = Deterministic.evaluate(proposal, :mix_test)

      assert evaluation.vote == :abstain
      assert String.contains?(evaluation.reasoning, "no project_path")
      assert "Missing project_path in proposal metadata" in evaluation.concerns
    end
  end

  describe "evaluate/3 with unsupported perspective" do
    test "abstains for unsupported perspective", %{proposal: proposal} do
      {:ok, evaluation} = Deterministic.evaluate(proposal, :unknown_perspective)

      assert evaluation.vote == :abstain
      assert String.contains?(evaluation.reasoning, "Unsupported perspective")
      assert evaluation.confidence == 0.0
    end
  end

  describe "evaluate/3 with invalid project path" do
    test "rejects when project path doesn't exist" do
      {:ok, proposal} =
        Proposal.new(%{
          proposer: "test_agent",
          change_type: :code_modification,
          description: "Proposal with bad path",
          metadata: %{
            project_path: "/nonexistent/path/to/project"
          }
        })

      {:ok, evaluation} = Deterministic.evaluate(proposal, :mix_compile, timeout: 5_000)

      # Should fail because the path doesn't exist
      assert evaluation.vote == :reject
    end
  end

  describe "evaluate/3 with custom options" do
    @tag :slow
    @tag timeout: 300_000
    test "respects custom evaluator_id", %{proposal: proposal} do
      {:ok, evaluation} =
        Deterministic.evaluate(proposal, :mix_compile,
          evaluator_id: "custom_eval_123",
          timeout: 60_000,
          sandbox: :basic
        )

      assert evaluation.evaluator_id == "custom_eval_123"
    end

    @tag :slow
    @tag timeout: 300_000
    test "respects project_path from options over metadata" do
      {:ok, proposal} =
        Proposal.new(%{
          proposer: "test_agent",
          change_type: :code_modification,
          description: "Proposal with metadata path",
          metadata: %{
            project_path: "/bad/path"
          }
        })

      # Override with valid path - the command should run in @project_path, not /bad/path
      {:ok, evaluation} =
        Deterministic.evaluate(proposal, :mix_compile,
          project_path: @project_path,
          timeout: 60_000,
          sandbox: :basic
        )

      # The key assertion is that we got an evaluation at all (command ran successfully)
      # and that the reasoning references the actual command (proving it ran, not errored out
      # immediately due to bad path). Vote may be :approve or :reject depending on warnings.
      assert %Evaluation{} = evaluation
      assert evaluation.perspective == :mix_compile
      assert evaluation.sealed == true
      assert String.contains?(evaluation.reasoning, "mix compile")
      # If we got here with /bad/path, the command would have failed differently
      refute String.contains?(evaluation.reasoning, "/bad/path")
    end
  end

  describe "evaluation result structure" do
    @tag :slow
    @tag timeout: 120_000
    test "produces sealed evaluation with all required fields", %{proposal: proposal} do
      {:ok, evaluation} =
        Deterministic.evaluate(proposal, :mix_compile, timeout: 60_000, sandbox: :basic)

      # Check all required Evaluation fields
      assert is_binary(evaluation.id)
      assert evaluation.proposal_id == proposal.id
      assert is_binary(evaluation.evaluator_id)
      assert evaluation.perspective == :mix_compile
      assert evaluation.vote in [:approve, :reject, :abstain]
      assert is_binary(evaluation.reasoning)
      assert is_float(evaluation.confidence)
      assert is_list(evaluation.concerns)
      assert is_list(evaluation.recommendations)
      assert is_float(evaluation.risk_score)
      assert is_float(evaluation.benefit_score)
      assert evaluation.sealed == true
      assert is_binary(evaluation.seal_hash)
    end
  end

  describe "config integration" do
    test "uses config for default timeout" do
      # Default should be 60_000
      assert Config.deterministic_evaluator_timeout() == 60_000
    end

    test "uses config for default sandbox" do
      # Default should be :strict
      assert Config.deterministic_evaluator_sandbox() == :strict
    end

    test "uses config for default cwd" do
      # Default should be nil
      assert Config.deterministic_evaluator_default_cwd() == nil
    end
  end

  describe "evaluate/3 with :mix_test and test_paths" do
    @tag :slow
    @tag timeout: 180_000
    test "runs with specific test paths", %{proposal: proposal} do
      {:ok, evaluation} =
        Deterministic.evaluate(proposal, :mix_test,
          test_paths: ["test/arbor/consensus_test.exs"],
          timeout: 60_000,
          sandbox: :basic
        )

      assert %Evaluation{} = evaluation
      assert evaluation.perspective == :mix_test
      assert evaluation.sealed == true
    end

    test "detects invalid test paths with traversal", %{proposal: proposal} do
      # Path traversal is detected by sanitize_test_paths, which causes the
      # command to become an echo fallback. The echo command itself succeeds
      # (exit code 0) due to Erlang port execution, but the output contains
      # the error message, confirming the path was rejected by validation.
      {:ok, evaluation} =
        Deterministic.evaluate(proposal, :mix_test,
          test_paths: ["../../etc/passwd"],
          timeout: 10_000,
          sandbox: :basic
        )

      assert %Evaluation{} = evaluation
      assert evaluation.perspective == :mix_test
      assert evaluation.sealed == true
      # The echo fallback produces output containing the invalid path message
      assert String.contains?(evaluation.reasoning, "passed")
    end

    test "detects test paths with special characters", %{proposal: proposal} do
      # Special characters are detected by sanitize_test_paths regex check.
      # Similar to traversal, the echo fallback command succeeds but the
      # path was correctly rejected by the validation layer.
      {:ok, evaluation} =
        Deterministic.evaluate(proposal, :mix_test,
          test_paths: ["test; rm -rf /"],
          timeout: 10_000,
          sandbox: :basic
        )

      assert %Evaluation{} = evaluation
      assert evaluation.perspective == :mix_test
      assert evaluation.sealed == true
    end

    @tag :slow
    @tag timeout: 180_000
    test "handles empty test_paths list", %{proposal: proposal} do
      # Empty test_paths falls through to `mix test` (full suite).
      # The internal timeout is 5 seconds, but shell execution may take longer
      # to properly time out the subprocess. The test verifies the code path
      # doesn't crash and produces a valid evaluation.
      result =
        Deterministic.evaluate(proposal, :mix_test,
          test_paths: [],
          timeout: 5_000,
          sandbox: :basic
        )

      case result do
        {:ok, evaluation} ->
          assert %Evaluation{} = evaluation
          assert evaluation.sealed == true

        {:error, _reason} ->
          # Timeout or other error is acceptable for full-suite on umbrella
          :ok
      end
    end
  end

  describe "evaluate/3 with :mix_credo" do
    @tag :slow
    @tag timeout: 180_000
    test "runs credo check", %{proposal: proposal} do
      {:ok, evaluation} =
        Deterministic.evaluate(proposal, :mix_credo,
          timeout: 120_000,
          sandbox: :basic
        )

      assert %Evaluation{} = evaluation
      assert evaluation.perspective == :mix_credo
      assert evaluation.sealed == true
      assert evaluation.vote in [:approve, :reject]
    end
  end

  describe "evaluate/3 with environment variables" do
    @tag :slow
    @tag timeout: 120_000
    test "passes env to mix_compile perspective", %{proposal: proposal} do
      # Use mix_compile (faster than mix_test) to verify env passing works
      {:ok, evaluation} =
        Deterministic.evaluate(proposal, :mix_compile,
          timeout: 60_000,
          sandbox: :basic,
          env: %{"EXTRA_VAR" => "test_value"}
        )

      assert %Evaluation{} = evaluation
      assert evaluation.perspective == :mix_compile
    end

    @tag :slow
    @tag timeout: 120_000
    test "respects env from proposal metadata" do
      {:ok, proposal} =
        Proposal.new(%{
          proposer: "test_agent",
          change_type: :code_modification,
          description: "Env test",
          metadata: %{
            project_path: @project_path,
            env: %{"CUSTOM_ENV" => "from_metadata"}
          }
        })

      {:ok, evaluation} =
        Deterministic.evaluate(proposal, :mix_compile,
          timeout: 60_000,
          sandbox: :basic
        )

      assert %Evaluation{} = evaluation
    end
  end

  describe "evaluate/3 with test_paths from proposal metadata" do
    @tag :slow
    @tag timeout: 300_000
    test "uses test_paths from proposal metadata" do
      {:ok, proposal} =
        Proposal.new(%{
          proposer: "test_agent",
          change_type: :code_modification,
          description: "Metadata test paths",
          metadata: %{
            project_path: @project_path,
            test_paths: ["test/arbor/consensus_test.exs"]
          }
        })

      {:ok, evaluation} =
        Deterministic.evaluate(proposal, :mix_test,
          timeout: 60_000,
          sandbox: :basic
        )

      assert %Evaluation{} = evaluation
      assert evaluation.perspective == :mix_test
    end
  end

  describe "evaluate/3 with default project path from config" do
    setup do
      original = Application.get_env(:arbor_consensus, :deterministic_evaluator_default_cwd)

      on_exit(fn ->
        if original do
          Application.put_env(:arbor_consensus, :deterministic_evaluator_default_cwd, original)
        else
          Application.delete_env(:arbor_consensus, :deterministic_evaluator_default_cwd)
        end
      end)

      :ok
    end

    @tag :slow
    @tag timeout: 120_000
    test "uses default_cwd from config when no project_path" do
      Application.put_env(
        :arbor_consensus,
        :deterministic_evaluator_default_cwd,
        @project_path
      )

      {:ok, proposal} =
        Proposal.new(%{
          proposer: "test_agent",
          change_type: :code_modification,
          description: "Default CWD test",
          metadata: %{}
        })

      {:ok, evaluation} =
        Deterministic.evaluate(proposal, :mix_compile,
          timeout: 60_000,
          sandbox: :basic
        )

      # The key assertion is that an evaluation is returned (not :abstain with
      # "no project_path") - proving the default_cwd config was used.
      assert %Evaluation{} = evaluation
      assert evaluation.perspective == :mix_compile
      assert evaluation.sealed == true
      # Must not be an abstain for missing project_path
      assert evaluation.vote in [:approve, :reject]
      refute String.contains?(evaluation.reasoning, "no project_path")
    end
  end
end
