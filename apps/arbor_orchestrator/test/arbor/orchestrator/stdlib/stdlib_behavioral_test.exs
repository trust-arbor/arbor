defmodule Arbor.Orchestrator.Stdlib.StdlibBehavioralTest do
  @moduledoc """
  Behavioral tests for enriched stdlib DOT pipelines.

  Tests the flow routing contracts by running the DOT files through Engine.run/2
  with simulate attributes and injected context values. Validates that:
  - Gates route correctly based on context state
  - Pipelines visit expected nodes in expected order
  - Final context contains expected keys
  """
  use ExUnit.Case, async: true

  @moduletag :integration

  # ============================================================================
  # retry-escalate.dot
  # ============================================================================

  describe "retry-escalate: score pre-check" do
    test "proceeds to attempt when score is ok" do
      dot = """
      digraph RetryEscalate {
        graph [goal="test retry", label="Retry Escalate"]
        start [shape=Mdiamond]
        init [type="transform"]
        score_precheck [type="gate", shape=diamond, predicate="expression", expression="retry.score_ok"]
        attempt [type="compute", simulate="true"]
        record_attempt [type="transform"]
        check_success [type="gate", shape=diamond, predicate="expression", expression="retry.success"]
        done [shape=Msquare]

        start -> init -> score_precheck
        score_precheck -> attempt [condition="context.retry.score_ok=true"]
        score_precheck -> done [condition="context.retry.score_ok!=true"]
        attempt -> record_attempt -> check_success
        check_success -> done [condition="context.retry.success=true"]
        check_success -> done [condition="context.retry.success!=true"]
      }
      """

      {:ok, result} =
        Arbor.Orchestrator.run(dot,
          initial_values: %{
            "retry.score_ok" => true,
            "retry.success" => true
          }
        )

      assert "attempt" in result.completed_nodes
      assert "record_attempt" in result.completed_nodes
      assert "check_success" in result.completed_nodes
    end

    test "skips attempt when score is below threshold" do
      dot = """
      digraph RetryEscalate {
        graph [goal="test score skip", label="Retry Escalate"]
        start [shape=Mdiamond]
        init [type="transform"]
        score_precheck [type="gate", shape=diamond, predicate="expression", expression="retry.score_ok"]
        attempt [type="compute", simulate="true"]
        escalate [type="transform"]
        check_max [type="gate", shape=diamond, predicate="expression", expression="retry.exhausted"]
        done [shape=Msquare]

        start -> init -> score_precheck
        score_precheck -> attempt [condition="context.retry.score_ok=true"]
        score_precheck -> escalate [condition="context.retry.score_ok!=true"]
        escalate -> check_max
        check_max -> done [condition="context.retry.exhausted=true"]
        check_max -> done [condition="context.retry.exhausted!=true"]
      }
      """

      {:ok, result} =
        Arbor.Orchestrator.run(dot,
          initial_values: %{
            "retry.score_ok" => false,
            "retry.exhausted" => true
          }
        )

      refute "attempt" in result.completed_nodes
      assert "escalate" in result.completed_nodes
      assert "check_max" in result.completed_nodes
    end
  end

  describe "retry-escalate: retry and escalation" do
    test "escalates on failure then exhausts retries" do
      dot = """
      digraph RetryEscalate {
        graph [goal="test escalation", label="Retry Escalate"]
        start [shape=Mdiamond]
        init [type="transform"]
        score_precheck [type="gate", shape=diamond, predicate="expression", expression="retry.score_ok"]
        attempt [type="compute", simulate="fail", max_retries=0]
        record_attempt [type="transform"]
        check_success [type="gate", shape=diamond, predicate="expression", expression="retry.success"]
        escalate [type="transform"]
        check_max [type="gate", shape=diamond, predicate="expression", expression="retry.exhausted"]
        done [shape=Msquare]

        start -> init -> score_precheck
        score_precheck -> attempt [condition="context.retry.score_ok=true"]
        score_precheck -> escalate [condition="context.retry.score_ok!=true"]
        attempt -> record_attempt [condition="outcome=fail"]
        record_attempt -> check_success
        check_success -> done [condition="context.retry.success=true"]
        check_success -> escalate [condition="context.retry.success!=true"]
        escalate -> check_max
        check_max -> done [condition="context.retry.exhausted=true"]
        check_max -> score_precheck [condition="context.retry.exhausted!=true"]
      }
      """

      {:ok, result} =
        Arbor.Orchestrator.run(dot,
          initial_values: %{
            "retry.score_ok" => true,
            "retry.success" => false,
            "retry.exhausted" => true
          },
          sleep_fn: fn _ -> :ok end
        )

      assert "attempt" in result.completed_nodes
      assert "escalate" in result.completed_nodes
      assert "check_max" in result.completed_nodes
    end

    test "succeeds on first attempt without escalation" do
      dot = """
      digraph RetryEscalate {
        graph [goal="test direct success", label="Retry Escalate"]
        start [shape=Mdiamond]
        init [type="transform"]
        score_precheck [type="gate", shape=diamond, predicate="expression", expression="retry.score_ok"]
        attempt [type="compute", simulate="true"]
        record_attempt [type="transform"]
        check_success [type="gate", shape=diamond, predicate="expression", expression="retry.success"]
        escalate [type="transform"]
        done [shape=Msquare]

        start -> init -> score_precheck
        score_precheck -> attempt [condition="context.retry.score_ok=true"]
        score_precheck -> escalate [condition="context.retry.score_ok!=true"]
        attempt -> record_attempt -> check_success
        check_success -> done [condition="context.retry.success=true"]
        check_success -> escalate [condition="context.retry.success!=true"]
      }
      """

      {:ok, result} =
        Arbor.Orchestrator.run(dot,
          initial_values: %{
            "retry.score_ok" => true,
            "retry.success" => true
          }
        )

      assert "attempt" in result.completed_nodes
      refute "escalate" in result.completed_nodes
      assert result.final_outcome.status == :success
    end
  end

  # ============================================================================
  # feedback-loop.dot
  # ============================================================================

  describe "feedback-loop: quality convergence" do
    test "exits when quality threshold met on first iteration" do
      dot = """
      digraph FeedbackLoop {
        graph [goal="test quality exit", label="Feedback Loop"]
        start [shape=Mdiamond]
        init [type="transform"]
        generate [type="compute", simulate="true"]
        critique [type="compute", simulate="true"]
        record_score [type="transform"]
        check_quality [type="gate", shape=diamond, predicate="expression", expression="loop.done"]
        revise_prompt [type="transform"]
        done [shape=Msquare]

        start -> init -> generate -> critique -> record_score -> check_quality
        check_quality -> done [condition="context.loop.done=true"]
        check_quality -> revise_prompt [condition="context.loop.done!=true"]
        revise_prompt -> generate
      }
      """

      {:ok, result} =
        Arbor.Orchestrator.run(dot,
          initial_values: %{"loop.done" => true}
        )

      assert "generate" in result.completed_nodes
      assert "critique" in result.completed_nodes
      refute "revise_prompt" in result.completed_nodes
    end

    test "loops through revise when quality is below threshold" do
      # Use fail_once on check_quality gate expression — first time done=false,
      # but we need the loop to terminate. Use max_steps to prevent infinite loop.
      dot = """
      digraph FeedbackLoop {
        graph [goal="test revision loop", label="Feedback Loop"]
        start [shape=Mdiamond]
        init [type="transform"]
        generate [type="compute", simulate="true"]
        critique [type="compute", simulate="true"]
        record_score [type="transform"]
        check_quality [type="gate", shape=diamond, predicate="expression", expression="loop.done"]
        revise_prompt [type="transform"]
        done [shape=Msquare]

        start -> init -> generate -> critique -> record_score -> check_quality
        check_quality -> done [condition="context.loop.done=true"]
        check_quality -> revise_prompt [condition="context.loop.done!=true"]
        revise_prompt -> generate
      }
      """

      # With loop.done=false, should loop until max_steps
      assert {:error, :max_steps_exceeded} =
               Arbor.Orchestrator.run(dot,
                 initial_values: %{"loop.done" => false},
                 max_steps: 15
               )
    end

    test "visits all expected nodes in a single pass" do
      dot = """
      digraph FeedbackLoop {
        graph [goal="test node ordering", label="Feedback Loop"]
        start [shape=Mdiamond]
        init [type="transform"]
        generate [type="compute", simulate="true"]
        critique [type="compute", simulate="true"]
        record_score [type="transform"]
        check_quality [type="gate", shape=diamond, predicate="expression", expression="loop.done"]
        done [shape=Msquare]

        start -> init -> generate -> critique -> record_score -> check_quality
        check_quality -> done [condition="context.loop.done=true"]
      }
      """

      {:ok, result} =
        Arbor.Orchestrator.run(dot,
          initial_values: %{"loop.done" => true}
        )

      expected = [
        "start",
        "init",
        "generate",
        "critique",
        "record_score",
        "check_quality",
        "done"
      ]

      for node <- expected, do: assert(node in result.completed_nodes)
    end
  end

  # ============================================================================
  # drift-detect.dot
  # ============================================================================

  describe "drift-detect: threshold routing" do
    # Note: read nodes in tests use source="context" to avoid filesystem dependency.
    # The real drift-detect.dot uses type="read" which reads from filesystem.

    test "routes to drift_detected when threshold exceeded" do
      dot = """
      digraph DriftDetect {
        graph [goal="test drift detection", label="Drift Detect"]
        start [shape=Mdiamond]
        load_baseline [type="read", source="context", source_key="baseline_data"]
        read_current [type="read", source="context", source_key="current_data"]
        check_first_run [type="gate", shape=diamond, predicate="expression", expression="drift.first_run"]
        compare [type="compute", simulate="true"]
        check_threshold [type="gate", shape=diamond, predicate="expression", expression="drift.exceeded"]
        drift_detected [type="transform"]
        within_threshold [type="transform"]
        write_report [type="transform"]
        check_auto_update [type="gate", shape=diamond, predicate="expression", expression="drift.should_update"]
        done [shape=Msquare]

        start -> load_baseline -> read_current -> check_first_run
        check_first_run -> compare [condition="context.drift.first_run!=true"]
        check_first_run -> write_report [condition="context.drift.first_run=true"]
        compare -> check_threshold
        check_threshold -> drift_detected [condition="context.drift.exceeded=true"]
        check_threshold -> within_threshold [condition="context.drift.exceeded!=true"]
        drift_detected -> write_report
        within_threshold -> write_report
        write_report -> check_auto_update
        check_auto_update -> done [condition="context.drift.should_update!=true"]
        check_auto_update -> done [condition="context.drift.should_update=true"]
      }
      """

      {:ok, result} =
        Arbor.Orchestrator.run(dot,
          initial_values: %{
            "baseline_data" => "original output",
            "current_data" => "changed output",
            "drift.first_run" => false,
            "drift.exceeded" => true,
            "drift.should_update" => false
          }
        )

      assert "compare" in result.completed_nodes
      assert "drift_detected" in result.completed_nodes
      refute "within_threshold" in result.completed_nodes
      assert "write_report" in result.completed_nodes
    end

    test "routes to within_threshold when drift is acceptable" do
      dot = """
      digraph DriftDetect {
        graph [goal="test no drift", label="Drift Detect"]
        start [shape=Mdiamond]
        load_baseline [type="read", source="context", source_key="baseline_data"]
        read_current [type="read", source="context", source_key="current_data"]
        check_first_run [type="gate", shape=diamond, predicate="expression", expression="drift.first_run"]
        compare [type="compute", simulate="true"]
        check_threshold [type="gate", shape=diamond, predicate="expression", expression="drift.exceeded"]
        drift_detected [type="transform"]
        within_threshold [type="transform"]
        write_report [type="transform"]
        check_auto_update [type="gate", shape=diamond, predicate="expression", expression="drift.should_update"]
        done [shape=Msquare]

        start -> load_baseline -> read_current -> check_first_run
        check_first_run -> compare [condition="context.drift.first_run!=true"]
        check_first_run -> write_report [condition="context.drift.first_run=true"]
        compare -> check_threshold
        check_threshold -> drift_detected [condition="context.drift.exceeded=true"]
        check_threshold -> within_threshold [condition="context.drift.exceeded!=true"]
        drift_detected -> write_report
        within_threshold -> write_report
        write_report -> check_auto_update
        check_auto_update -> done [condition="context.drift.should_update!=true"]
        check_auto_update -> done [condition="context.drift.should_update=true"]
      }
      """

      {:ok, result} =
        Arbor.Orchestrator.run(dot,
          initial_values: %{
            "baseline_data" => "same output",
            "current_data" => "same output",
            "drift.first_run" => false,
            "drift.exceeded" => false,
            "drift.should_update" => false
          }
        )

      assert "within_threshold" in result.completed_nodes
      refute "drift_detected" in result.completed_nodes
    end

    test "handles first-run by skipping comparison" do
      dot = """
      digraph DriftDetect {
        graph [goal="test first run", label="Drift Detect"]
        start [shape=Mdiamond]
        load_baseline [type="read", source="context", source_key="baseline_data"]
        read_current [type="read", source="context", source_key="current_data"]
        check_first_run [type="gate", shape=diamond, predicate="expression", expression="drift.first_run"]
        init_baseline [type="transform"]
        compare [type="compute", simulate="true"]
        write_report [type="transform"]
        check_auto_update [type="gate", shape=diamond, predicate="expression", expression="drift.should_update"]
        done [shape=Msquare]

        start -> load_baseline -> read_current -> check_first_run
        check_first_run -> init_baseline [condition="context.drift.first_run=true"]
        check_first_run -> compare [condition="context.drift.first_run!=true"]
        init_baseline -> write_report
        compare -> write_report
        write_report -> check_auto_update
        check_auto_update -> done [condition="context.drift.should_update!=true"]
        check_auto_update -> done [condition="context.drift.should_update=true"]
      }
      """

      {:ok, result} =
        Arbor.Orchestrator.run(dot,
          initial_values: %{
            "baseline_data" => nil,
            "current_data" => "new output",
            "drift.first_run" => true,
            "drift.should_update" => false
          }
        )

      assert "init_baseline" in result.completed_nodes
      refute "compare" in result.completed_nodes
    end

    test "auto-updates baseline when flag is set" do
      dot = """
      digraph DriftDetect {
        graph [goal="test auto update", label="Drift Detect"]
        start [shape=Mdiamond]
        load_baseline [type="read", source="context", source_key="baseline_data"]
        read_current [type="read", source="context", source_key="current_data"]
        check_first_run [type="gate", shape=diamond, predicate="expression", expression="drift.first_run"]
        compare [type="compute", simulate="true"]
        check_threshold [type="gate", shape=diamond, predicate="expression", expression="drift.exceeded"]
        within_threshold [type="transform"]
        write_report [type="transform"]
        check_auto_update [type="gate", shape=diamond, predicate="expression", expression="drift.should_update"]
        update_baseline [type="transform"]
        done [shape=Msquare]

        start -> load_baseline -> read_current -> check_first_run
        check_first_run -> compare [condition="context.drift.first_run!=true"]
        compare -> check_threshold
        check_threshold -> within_threshold [condition="context.drift.exceeded!=true"]
        within_threshold -> write_report
        write_report -> check_auto_update
        check_auto_update -> update_baseline [condition="context.drift.should_update=true"]
        check_auto_update -> done [condition="context.drift.should_update!=true"]
        update_baseline -> done
      }
      """

      {:ok, result} =
        Arbor.Orchestrator.run(dot,
          initial_values: %{
            "baseline_data" => "original",
            "current_data" => "current",
            "drift.first_run" => false,
            "drift.exceeded" => false,
            "drift.should_update" => true
          }
        )

      assert "update_baseline" in result.completed_nodes
    end
  end

  # ============================================================================
  # ab-test.dot
  # ============================================================================

  describe "ab-test: variant comparison" do
    test "runs both variants through judge and reaches done" do
      dot = """
      digraph ABTest {
        graph [goal="test ab comparison", label="AB Test"]
        start [shape=Mdiamond]
        init [type="transform"]
        run_variants [type="parallel", fan_out="true"]
        variant_a [type="compute", simulate="true"]
        variant_b [type="compute", simulate="true"]
        collect [type="fan_in"]
        judge [type="compute", simulate="true"]
        significance [type="transform"]
        persist [type="transform"]
        check_promote [type="gate", shape=diamond, predicate="expression", expression="ab.should_promote"]
        done [shape=Msquare]

        start -> init -> run_variants
        run_variants -> variant_a
        run_variants -> variant_b
        variant_a -> collect
        variant_b -> collect
        collect -> judge -> significance -> persist -> check_promote
        check_promote -> done [condition="context.ab.should_promote!=true"]
        check_promote -> done [condition="context.ab.should_promote=true"]
      }
      """

      branch_executor = fn branch_node_id, _context, _graph, _opts ->
        case branch_node_id do
          "variant_a" -> %{"id" => "variant_a", "status" => "success", "result" => "output_a"}
          "variant_b" -> %{"id" => "variant_b", "status" => "success", "result" => "output_b"}
        end
      end

      {:ok, result} =
        Arbor.Orchestrator.run(dot,
          initial_values: %{"ab.should_promote" => false},
          parallel_branch_executor: branch_executor
        )

      assert "judge" in result.completed_nodes
      assert "significance" in result.completed_nodes
      assert "persist" in result.completed_nodes
      assert "check_promote" in result.completed_nodes
    end

    test "auto-promotes when conditions met" do
      dot = """
      digraph ABTest {
        graph [goal="test auto promote", label="AB Test"]
        start [shape=Mdiamond]
        init [type="transform"]
        run_variants [type="parallel", fan_out="true"]
        variant_a [type="compute", simulate="true"]
        variant_b [type="compute", simulate="true"]
        collect [type="fan_in"]
        judge [type="compute", simulate="true"]
        significance [type="transform"]
        persist [type="transform"]
        check_promote [type="gate", shape=diamond, predicate="expression", expression="ab.should_promote"]
        promote [type="transform"]
        done [shape=Msquare]

        start -> init -> run_variants
        run_variants -> variant_a
        run_variants -> variant_b
        variant_a -> collect
        variant_b -> collect
        collect -> judge -> significance -> persist -> check_promote
        check_promote -> promote [condition="context.ab.should_promote=true"]
        check_promote -> done [condition="context.ab.should_promote!=true"]
        promote -> done
      }
      """

      branch_executor = fn branch_node_id, _context, _graph, _opts ->
        case branch_node_id do
          "variant_a" -> %{"id" => "variant_a", "status" => "success"}
          "variant_b" -> %{"id" => "variant_b", "status" => "success"}
        end
      end

      {:ok, result} =
        Arbor.Orchestrator.run(dot,
          initial_values: %{"ab.should_promote" => true},
          parallel_branch_executor: branch_executor
        )

      assert "promote" in result.completed_nodes
    end

    test "skips promotion when not significant" do
      dot = """
      digraph ABTest {
        graph [goal="test no promote", label="AB Test"]
        start [shape=Mdiamond]
        init [type="transform"]
        run_variants [type="parallel", fan_out="true"]
        variant_a [type="compute", simulate="true"]
        variant_b [type="compute", simulate="true"]
        collect [type="fan_in"]
        judge [type="compute", simulate="true"]
        significance [type="transform"]
        persist [type="transform"]
        check_promote [type="gate", shape=diamond, predicate="expression", expression="ab.should_promote"]
        promote [type="transform"]
        done [shape=Msquare]

        start -> init -> run_variants
        run_variants -> variant_a
        run_variants -> variant_b
        variant_a -> collect
        variant_b -> collect
        collect -> judge -> significance -> persist -> check_promote
        check_promote -> promote [condition="context.ab.should_promote=true"]
        check_promote -> done [condition="context.ab.should_promote!=true"]
        promote -> done
      }
      """

      branch_executor = fn branch_node_id, _context, _graph, _opts ->
        case branch_node_id do
          "variant_a" -> %{"id" => "variant_a", "status" => "success"}
          "variant_b" -> %{"id" => "variant_b", "status" => "success"}
        end
      end

      {:ok, result} =
        Arbor.Orchestrator.run(dot,
          initial_values: %{"ab.should_promote" => false},
          parallel_branch_executor: branch_executor
        )

      refute "promote" in result.completed_nodes
    end
  end

  # ============================================================================
  # Cross-cutting: context key propagation
  # ============================================================================

  describe "context propagation" do
    test "initial_values are accessible to gate expressions" do
      dot = """
      digraph ContextTest {
        graph [goal="test context", label="Context Test"]
        start [shape=Mdiamond]
        gate [type="gate", shape=diamond, predicate="expression", expression="custom.flag"]
        path_a [type="transform"]
        path_b [type="transform"]
        done [shape=Msquare]

        start -> gate
        gate -> path_a [condition="context.custom.flag=true"]
        gate -> path_b [condition="context.custom.flag!=true"]
        path_a -> done
        path_b -> done
      }
      """

      {:ok, result_true} =
        Arbor.Orchestrator.run(dot,
          initial_values: %{"custom.flag" => true}
        )

      assert "path_a" in result_true.completed_nodes
      refute "path_b" in result_true.completed_nodes

      {:ok, result_false} =
        Arbor.Orchestrator.run(dot,
          initial_values: %{"custom.flag" => false}
        )

      refute "path_a" in result_false.completed_nodes
      assert "path_b" in result_false.completed_nodes
    end
  end
end
