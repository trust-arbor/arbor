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
