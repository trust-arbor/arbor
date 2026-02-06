defmodule Arbor.Demo.OrchestratorTest do
  @moduledoc """
  End-to-end integration tests for the self-healing demo pipeline.

  Tests the full flow: Inject fault -> Monitor detects -> DebugAgent proposes ->
  Council evaluates -> Decision rendered.

  Tagged :integration and excluded by default. Run with:

      mix test --include integration apps/arbor_demo/test/arbor/demo/orchestrator_test.exs
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Consensus.{ChangeProposal, Evaluation, Proposal}
  alias Arbor.Demo.{EvaluatorConfig, Orchestrator}

  @moduletag :integration
  @moduletag :slow

  describe "EvaluatorConfig" do
    test "returns evaluator specs" do
      specs = EvaluatorConfig.evaluator_specs()

      # Single unified evaluator for demo
      assert length(specs) == 1
      [spec] = specs
      assert spec.name == :demo_evaluator
      assert :safety_check in spec.perspectives
      assert :vulnerability_scan in spec.perspectives
      assert :performance_impact in spec.perspectives
    end

    test "identifies protected modules" do
      # These should be protected
      assert EvaluatorConfig.protected_module?(Arbor.Security)
      assert EvaluatorConfig.protected_module?(Arbor.Security.Kernel)
      assert EvaluatorConfig.protected_module?(Arbor.Consensus.Coordinator)
      assert EvaluatorConfig.protected_module?(Arbor.Persistence)

      # These should not be protected
      refute EvaluatorConfig.protected_module?(Arbor.Demo.FaultInjector)
      refute EvaluatorConfig.protected_module?(MyApp.Worker)
    end

    test "returns protected modules list" do
      modules = EvaluatorConfig.protected_modules()
      assert is_list(modules)
      assert modules != []
      assert Arbor.Security.Kernel in modules
    end
  end

  describe "EvaluatorConfig.evaluate/3" do
    setup do
      # Create a valid ChangeProposal
      {:ok, change_proposal} =
        ChangeProposal.new(%{
          module: MyApp.Worker,
          change_type: :hot_load,
          source_code: "defmodule MyApp.Worker do end",
          rationale: "Fix process leak",
          evidence: ["anomaly_123"],
          rollback_plan: "Reload previous version from disk",
          estimated_impact: :low
        })

      # Create a proposal with the change_proposal in context
      {:ok, proposal} =
        Proposal.new(%{
          proposer: "debug-agent",
          topic: :runtime_fix,
          description: "Fix process leak in MyApp.Worker",
          context: %{change_proposal: change_proposal}
        })

      {:ok, proposal: proposal, change_proposal: change_proposal}
    end

    test "safety_check approves non-protected modules", %{proposal: proposal} do
      {:ok, eval} = EvaluatorConfig.evaluate(proposal, :safety_check, [])

      assert eval.vote == :approve
      assert eval.confidence == 0.95
      assert eval.concerns == []
    end

    test "safety_check rejects protected modules" do
      {:ok, change_proposal} =
        ChangeProposal.new(%{
          module: Arbor.Security.Kernel,
          change_type: :hot_load,
          source_code: "defmodule Arbor.Security.Kernel do end",
          rationale: "Attempt to modify kernel",
          evidence: ["anomaly_456"],
          rollback_plan: "Reload previous version",
          estimated_impact: :high
        })

      {:ok, proposal} =
        Proposal.new(%{
          proposer: "debug-agent",
          topic: :runtime_fix,
          description: "Modify security kernel",
          context: %{change_proposal: change_proposal}
        })

      {:ok, eval} = EvaluatorConfig.evaluate(proposal, :safety_check, [])

      assert eval.vote == :reject
      assert String.contains?(eval.reasoning, "Protected module")
    end

    test "rollback_verification rejects empty rollback plans" do
      {:ok, change_proposal} =
        ChangeProposal.new(%{
          module: MyApp.Worker,
          change_type: :hot_load,
          source_code: "defmodule MyApp.Worker do end",
          rationale: "Fix something",
          evidence: [],
          rollback_plan: "",
          estimated_impact: :low
        })

      {:ok, proposal} =
        Proposal.new(%{
          proposer: "debug-agent",
          topic: :runtime_fix,
          description: "Fix with no rollback",
          context: %{change_proposal: change_proposal}
        })

      {:ok, eval} = EvaluatorConfig.evaluate(proposal, :rollback_verification, [])

      assert eval.vote == :reject
      assert String.contains?(eval.reasoning, "rollback")
    end

    test "rollback_verification rejects vague rollback plans" do
      {:ok, change_proposal} =
        ChangeProposal.new(%{
          module: MyApp.Worker,
          change_type: :hot_load,
          source_code: "defmodule MyApp.Worker do end",
          rationale: "Fix something",
          evidence: [],
          rollback_plan: "TBD",
          estimated_impact: :low
        })

      {:ok, proposal} =
        Proposal.new(%{
          proposer: "debug-agent",
          topic: :runtime_fix,
          description: "Fix with vague rollback",
          context: %{change_proposal: change_proposal}
        })

      {:ok, eval} = EvaluatorConfig.evaluate(proposal, :rollback_verification, [])

      assert eval.vote == :reject
      assert String.contains?(eval.reasoning, "vague")
    end

    test "policy_compliance rejects high-impact with insufficient evidence" do
      {:ok, change_proposal} =
        ChangeProposal.new(%{
          module: MyApp.Worker,
          change_type: :hot_load,
          source_code: "defmodule MyApp.Worker do end",
          rationale: "Major change",
          evidence: ["one_item"],
          rollback_plan: "Reload previous version from disk backup",
          estimated_impact: :high
        })

      {:ok, proposal} =
        Proposal.new(%{
          proposer: "debug-agent",
          topic: :runtime_fix,
          description: "High-impact with little evidence",
          context: %{change_proposal: change_proposal}
        })

      {:ok, eval} = EvaluatorConfig.evaluate(proposal, :policy_compliance, [])

      assert eval.vote == :reject
      assert String.contains?(eval.reasoning, "evidence")
    end

    test "policy_compliance approves high-impact with sufficient evidence" do
      {:ok, change_proposal} =
        ChangeProposal.new(%{
          module: MyApp.Worker,
          change_type: :hot_load,
          source_code: "defmodule MyApp.Worker do end",
          rationale: "Major change",
          evidence: ["anomaly_1", "anomaly_2", "anomaly_3"],
          rollback_plan: "Reload previous version from disk backup",
          estimated_impact: :high
        })

      {:ok, proposal} =
        Proposal.new(%{
          proposer: "debug-agent",
          topic: :runtime_fix,
          description: "High-impact with evidence",
          context: %{change_proposal: change_proposal}
        })

      {:ok, eval} = EvaluatorConfig.evaluate(proposal, :policy_compliance, [])

      assert eval.vote == :approve
    end
  end

  describe "ChangeProposal" do
    test "creates valid hot_load proposal" do
      {:ok, cp} =
        ChangeProposal.new(%{
          module: MyApp.Worker,
          change_type: :hot_load,
          source_code: "defmodule MyApp.Worker do end",
          rationale: "Fix process leak",
          evidence: ["anomaly_123"],
          rollback_plan: "Reload previous version",
          estimated_impact: :low
        })

      assert cp.module == MyApp.Worker
      assert cp.change_type == :hot_load
      assert cp.source_code == "defmodule MyApp.Worker do end"
      assert ChangeProposal.valid?(cp)
    end

    test "rejects hot_load without source_code" do
      result =
        ChangeProposal.new(%{
          module: MyApp.Worker,
          change_type: :hot_load,
          rationale: "Fix something",
          rollback_plan: "Reload previous version",
          estimated_impact: :low
        })

      assert {:error, {:validation_error, _}} = result
    end

    test "creates valid config_change proposal" do
      {:ok, cp} =
        ChangeProposal.new(%{
          module: MyApp.Worker,
          change_type: :config_change,
          config_changes: %{timeout: 5000},
          rationale: "Increase timeout",
          evidence: [],
          rollback_plan: "Revert config to previous value",
          estimated_impact: :low
        })

      assert cp.change_type == :config_change
      assert cp.config_changes == %{timeout: 5000}
      assert ChangeProposal.valid?(cp)
    end

    test "creates valid restart proposal" do
      {:ok, cp} =
        ChangeProposal.new(%{
          module: MyApp.Worker,
          change_type: :restart,
          rationale: "Process stuck",
          evidence: ["process_hung"],
          rollback_plan: "N/A - restart is safe",
          estimated_impact: :low
        })

      assert cp.change_type == :restart
      assert ChangeProposal.valid?(cp)
    end

    test "to_context returns proposal context map" do
      {:ok, cp} =
        ChangeProposal.new(%{
          module: MyApp.Worker,
          change_type: :hot_load,
          source_code: "defmodule MyApp.Worker do end",
          rationale: "Fix process leak",
          evidence: ["anomaly_123"],
          rollback_plan: "Reload previous version",
          estimated_impact: :medium
        })

      context = ChangeProposal.to_context(cp)

      assert context.change_proposal == cp
      assert context.target_module == MyApp.Worker
      assert context.new_code == "defmodule MyApp.Worker do end"
      assert context.change_type == :hot_load
      assert context.estimated_impact == :medium
    end
  end

  describe "Orchestrator" do
    @tag :skip
    test "starts and stops cleanly" do
      # This test requires the full application to be running
      # Skip in unit test mode
      {:ok, pid} = Orchestrator.start_link([])
      assert Process.alive?(pid)

      state = Orchestrator.state()
      assert state.pipeline_stage == :idle

      GenServer.stop(pid)
      refute Process.alive?(pid)
    end
  end

  describe "signal flow integration" do
    @tag :skip
    test "fault injection triggers pipeline stages" do
      # This test requires Monitor and Signals to be running
      # Skip in unit test mode, run manually with --include integration

      # 1. Verify initial state
      assert Orchestrator.pipeline_stage() == :idle

      # 2. Inject fault
      {:ok, :message_queue_flood} = Arbor.Demo.inject_fault(:message_queue_flood)

      # 3. Wait for pipeline to progress
      Process.sleep(1000)

      # 4. Verify pipeline stage changed
      stage = Orchestrator.pipeline_stage()
      assert stage in [:detect, :diagnose, :propose, :review]

      # 5. Clean up
      Arbor.Demo.clear_all()
      Orchestrator.reset()
    end
  end
end
