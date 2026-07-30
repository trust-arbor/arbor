defmodule Arbor.Actions.Coding.SecurityRegression.CoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Coding.SecurityRegression.Core

  @moduletag :fast

  test "accepts only the bounded opaque review-attestation input" do
    assert {:ok, input} =
             Core.new(%{
               review_attestation_id: "review_attestation_opaque",
               timeout: 10_000
             })

    assert input.review_attestation_id == "review_attestation_opaque"
    assert input.timeout == 10_000
    assert input.stage_timeout == nil

    assert {:ok, %{timeout: 300_000}} =
             Core.new(%{review_attestation_id: "review_attestation_opaque"})

    assert Core.maximum_timeout() == Arbor.Shell.spawn_capable_max_timeout_ms()

    assert {:ok, %{timeout: 600_000}} =
             Core.new(%{
               review_attestation_id: "review_attestation_opaque",
               timeout: "600000"
             })

    for invalid <- ["600001", "999", "0600000", "600000ms", " 600000"] do
      assert {:error, :invalid_timeout} =
               Core.new(%{
                 review_attestation_id: "review_attestation_opaque",
                 timeout: invalid
               })
    end

    assert {:error, :unsupported_parameter} =
             Core.new(%{
               review_attestation_id: "review_attestation_opaque",
               command: "mix test"
             })

    assert {:error, :unsupported_parameter} =
             Core.new(%{
               review_attestation_id: "review_attestation_opaque",
               test_paths: ["test/z_test.exs", "test/a_test.exs"]
             })

    assert {:error, :unsupported_parameter} =
             Core.new(%{
               workspace_id: "ws_opaque",
               review_attestation_id: "review_attestation_opaque"
             })
  end

  test "accepts a bounded aggregate stage timeout and preserves legacy nil" do
    assert {:ok, %{stage_timeout: 12_000}} =
             Core.new(%{
               review_attestation_id: "review_attestation_opaque",
               stage_timeout: "12000"
             })

    assert Core.maximum_stage_timeout() == 2 * Core.maximum_timeout()
    assert Core.maximum_stage_timeout() == 2 * Arbor.Shell.spawn_capable_max_timeout_ms()
    assert Core.maximum_stage_timeout() == 1_200_000

    assert {:ok, %{stage_timeout: 1_200_000}} =
             Core.new(%{
               review_attestation_id: "review_attestation_opaque",
               stage_timeout: 1_200_000
             })
  end

  test "rejects invalid or oversized aggregate stage timeouts" do
    for invalid <- [0, -1, "0", "-1", Integer.to_string(Core.maximum_stage_timeout() + 1)] do
      assert {:error, :invalid_stage_timeout} =
               Core.new(%{
                 review_attestation_id: "review_attestation_opaque",
                 stage_timeout: invalid
               })
    end
  end

  test "security regression: trusted timed_out becomes capacity with closed termination" do
    candidate = completed_leg_with_diagnostic(0, false)

    shell_timeout =
      Core.completed_leg(
        1,
        true,
        elem(
          Core.validate_artifact(
            {Core.artifact_tag(), Core.artifact_version(),
             %{artifact_counts() | executed: 1, passed: 1, test_failures: 0, total: 1}}
          ),
          1
        ),
        closed_diagnostic(1, true)
      )

    assert Core.verdict(shell_timeout, Core.not_run_leg()) == %{
             passed: false,
             reason: "validation_capacity_exceeded"
           }

    evidence =
      Core.show(%{
        base_commit: String.duplicate("b", 40),
        candidate_fingerprint: String.duplicate("c", 64),
        sources: [%{path: "test/a_test.exs", sha256: String.duplicate("d", 64)}],
        candidate: shell_timeout,
        base: Core.not_run_leg()
      })

    assert evidence.reason == "validation_capacity_exceeded"
    assert evidence.passed == false
    assert evidence.termination == Core.capacity_termination()
    assert evidence.termination["timed_out"] == true

    marked = Core.mark_capacity_leg(candidate)
    assert marked.timed_out == true
    assert marked.diagnostic["timed_out"] == true
    assert marked.diagnostic["exit_code"] == candidate.exit_code
    assert marked.diagnostic["output_bytes"] == candidate.diagnostic["output_bytes"]
    assert marked.diagnostic["output_sha256"] == candidate.diagnostic["output_sha256"]

    stage = Core.stage_timeout_leg()
    assert stage.status == :stage_timeout
    assert stage.timed_out == true
    assert stage.diagnostic["timed_out"] == true
    assert map_size(stage.diagnostic) > 0

    assert Core.verdict(candidate, stage).reason == "validation_capacity_exceeded"

    # Malformed/non-map input must not synthesize valid capacity evidence.
    for bad <- [nil, :not_a_leg, "leg", 42, %{}, %{status: :completed}] do
      closed = Core.mark_capacity_leg(bad)
      refute closed.timed_out
      refute Core.verdict(closed, Core.not_run_leg()).reason == "validation_capacity_exceeded"
    end
  end

  test "security regression: mark_capacity_leg rejects malformed diagnostics" do
    base = completed_leg_with_diagnostic(0, false)
    max_bytes = Arbor.Shell.max_output_bytes_limit()

    malformed_diagnostics = [
      # empty
      %{},
      # missing keys
      %{"exit_code" => 0, "timed_out" => false},
      # extra keys
      Map.put(closed_diagnostic(0, false), "extra", true),
      # exit_code mismatch vs leg
      closed_diagnostic(1, false),
      # timed_out mismatch vs leg
      closed_diagnostic(0, true),
      # invalid output_bytes
      %{
        "exit_code" => 0,
        "timed_out" => false,
        "output_bytes" => -1,
        "output_sha256" => String.duplicate("a", 64)
      },
      # above Shell output ceiling
      %{
        "exit_code" => 0,
        "timed_out" => false,
        "output_bytes" => max_bytes + 1,
        "output_sha256" => String.duplicate("a", 64)
      },
      # invalid hash (uppercase / wrong length)
      %{
        "exit_code" => 0,
        "timed_out" => false,
        "output_bytes" => 0,
        "output_sha256" => String.duplicate("A", 64)
      },
      %{
        "exit_code" => 0,
        "timed_out" => false,
        "output_bytes" => 0,
        "output_sha256" => "short"
      }
    ]

    for diagnostic <- malformed_diagnostics do
      leg = %{base | diagnostic: diagnostic}
      closed = Core.mark_capacity_leg(leg)
      refute closed.timed_out
      refute Core.verdict(closed, Core.not_run_leg()).reason == "validation_capacity_exceeded"
    end

    # Exact Shell ceiling is admitted; mark_capacity forces timed_out true.
    at_ceiling = %{
      base
      | diagnostic: %{
          "exit_code" => 0,
          "timed_out" => false,
          "output_bytes" => max_bytes,
          "output_sha256" => String.duplicate("a", 64)
        }
    }

    marked = Core.mark_capacity_leg(at_ceiling)
    assert marked.timed_out == true
    assert marked.diagnostic["output_bytes"] == max_bytes
    assert marked.diagnostic["timed_out"] == true
  end

  test "security regression: exit 137 without timed_out stays ordinary failure" do
    diagnostic = closed_diagnostic(137, false)

    candidate =
      Core.completed_leg(
        137,
        false,
        elem(
          Core.validate_artifact(
            {Core.artifact_tag(), Core.artifact_version(),
             %{artifact_counts() | executed: 1, passed: 1, test_failures: 0, total: 1}}
          ),
          1
        ),
        diagnostic
      )

    # Exit 137 alone is ordinary domain failure (nonzero exit), not capacity.
    assert candidate.exit_code == 137
    assert candidate.timed_out == false
    assert candidate.diagnostic["exit_code"] == 137
    assert candidate.diagnostic["timed_out"] == false
    assert Core.candidate_gate(candidate) == {:error, "candidate_exit_nonzero"}

    evidence =
      Core.show(%{
        base_commit: String.duplicate("b", 40),
        candidate_fingerprint: String.duplicate("c", 64),
        sources: [%{path: "test/a_test.exs", sha256: String.duplicate("d", 64)}],
        candidate: candidate,
        base: Core.not_run_leg()
      })

    assert evidence.reason == "candidate_exit_nonzero"
    assert evidence.termination == nil
    assert evidence.candidate.exit_code == 137
    assert evidence.candidate.timed_out == false
    assert evidence.diagnostics.candidate["exit_code"] == 137
    assert evidence.diagnostics.candidate["timed_out"] == false
    refute evidence.reason == "validation_capacity_exceeded"
  end

  test "validates the formatter artifact against an exact schema" do
    counts = artifact_counts()
    artifact = {Core.artifact_tag(), Core.artifact_version(), counts}

    assert {:ok, normalized} = Core.validate_artifact(artifact)
    assert normalized["executed"] == 2
    assert normalized["test_failures"] == 1

    assert {:error, :invalid_result_artifact} =
             Core.validate_artifact(
               {Core.artifact_tag(), Core.artifact_version(), Map.put(counts, :extra, 1)}
             )

    assert {:error, :invalid_result_artifact} =
             Core.validate_artifact(
               {Core.artifact_tag(), Core.artifact_version(), %{counts | total: 99}}
             )
  end

  test "requires candidate pass and a real base test failure" do
    candidate =
      completed_leg(%{artifact_counts() | executed: 1, passed: 1, test_failures: 0, total: 1})

    base = completed_leg(%{artifact_counts() | passed: 1, test_failures: 1, total: 2}, 2)

    assert Core.verdict(candidate, base) == %{
             passed: true,
             reason: "security_regression_validated"
           }

    base_passed = completed_leg(%{artifact_counts() | passed: 2, test_failures: 0}, 0)

    assert Core.verdict(candidate, base_passed) == %{
             passed: false,
             reason: "base_tests_passed"
           }

    non_test_exit =
      completed_leg(
        %{artifact_counts() | executed: 1, passed: 1, test_failures: 0, total: 1},
        17
      )

    assert Core.verdict(candidate, non_test_exit) == %{
             passed: false,
             reason: "base_non_test_failure"
           }
  end

  test "fails closed for setup failures and zero executed tests" do
    candidate =
      completed_leg(%{artifact_counts() | executed: 1, passed: 1, test_failures: 0, total: 1})

    setup_failure =
      completed_leg(%{
        artifact_counts()
        | executed: 0,
          passed: 0,
          test_failures: 0,
          setup_failures: 1,
          invalid: 1,
          total: 1
      })

    assert Core.verdict(candidate, setup_failure).reason == "base_setup_failed"

    zero_tests =
      completed_leg(%{
        artifact_counts()
        | executed: 0,
          passed: 0,
          test_failures: 0,
          total: 0
      })

    assert Core.candidate_gate(zero_tests) == {:error, "candidate_zero_tests"}
  end

  defp completed_leg(counts, exit_code \\ 0) do
    {:ok, normalized} =
      Core.validate_artifact({Core.artifact_tag(), Core.artifact_version(), counts})

    Core.completed_leg(exit_code, false, normalized, %{})
  end

  defp completed_leg_with_diagnostic(exit_code, timed_out) do
    {:ok, normalized} =
      Core.validate_artifact(
        {Core.artifact_tag(), Core.artifact_version(),
         %{artifact_counts() | executed: 1, passed: 1, test_failures: 0, total: 1}}
      )

    Core.completed_leg(exit_code, timed_out, normalized, closed_diagnostic(exit_code, timed_out))
  end

  defp closed_diagnostic(exit_code, timed_out) do
    %{
      "exit_code" => exit_code,
      "timed_out" => timed_out,
      "output_bytes" => 0,
      "output_sha256" => String.duplicate("a", 64)
    }
  end

  defp artifact_counts do
    %{
      excluded: 0,
      executed: 2,
      invalid: 0,
      max_failures_reached: false,
      passed: 1,
      setup_failures: 0,
      skipped: 0,
      suite_completed: true,
      suite_started: true,
      test_failures: 1,
      total: 2
    }
  end
end
