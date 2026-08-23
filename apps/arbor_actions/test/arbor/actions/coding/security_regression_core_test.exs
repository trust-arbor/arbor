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

    assert marked.diagnostic["untrusted_diagnostic_output"] ==
             candidate.diagnostic["untrusted_diagnostic_output"]

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
          "output_sha256" => String.duplicate("a", 64),
          "untrusted_diagnostic_output" => ""
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

    bootstrap_failure =
      completed_leg(%{
        artifact_counts()
        | executed: 0,
          passed: 0,
          test_failures: 0,
          setup_failures: 1,
          invalid: 0,
          total: 0,
          suite_started: false,
          suite_completed: false
      })

    assert Core.candidate_gate(bootstrap_failure) == {:error, "candidate_setup_failed"}
    assert Core.verdict(candidate, bootstrap_failure).reason == "base_setup_failed"
  end

  test "security regression: untrusted diagnostic excerpt is bounded and JSON-safe" do
    assert Core.untrusted_diagnostic_field() == "untrusted_diagnostic_output"
    limit = Core.untrusted_diagnostic_output_limit()
    assert limit == 2048

    empty = Core.child_diagnostic(0, false, "")
    assert empty["untrusted_diagnostic_output"] == ""
    assert empty["output_bytes"] == 0
    assert empty["output_sha256"] == sha256("")
    assert jason_object?(empty)

    short = "no such table: memory_relationships"
    short_diag = Core.child_diagnostic(2, false, short)
    assert short_diag["untrusted_diagnostic_output"] == short
    assert short_diag["output_bytes"] == byte_size(short)
    assert short_diag["output_sha256"] == sha256(short)
    assert jason_object?(short_diag)

    oversized = String.duplicate("x", limit + 64)
    oversized_diag = Core.child_diagnostic(2, false, oversized)
    excerpt = oversized_diag["untrusted_diagnostic_output"]
    assert byte_size(excerpt) <= limit
    assert String.valid?(excerpt)
    assert excerpt =~ Core.untrusted_omission_marker()
    assert oversized_diag["output_bytes"] == byte_size(oversized)
    assert oversized_diag["output_sha256"] == sha256(oversized)
    refute oversized_diag["output_sha256"] == sha256(excerpt)
    assert jason_object?(oversized_diag)
  end

  test "security regression: diagnostic hash covers unsanitized path-normalized bytes" do
    oversized_tail = String.duplicate("x", Core.untrusted_diagnostic_output_limit() + 32)
    path_normalized = "pre" <> <<0, 0xFF, 0xFE>> <> "post" <> oversized_tail
    diagnostic = Core.child_diagnostic(2, false, path_normalized)

    assert diagnostic["output_bytes"] == byte_size(path_normalized)
    assert diagnostic["output_sha256"] == sha256(path_normalized)

    excerpt = diagnostic["untrusted_diagnostic_output"]
    refute String.contains?(excerpt, <<0>>)
    assert String.valid?(excerpt)
    assert byte_size(excerpt) <= Core.untrusted_diagnostic_output_limit()
    assert jason_object?(diagnostic)
    refute diagnostic["output_sha256"] == sha256(excerpt)
    assert excerpt =~ "pre"
    assert excerpt =~ "post"
  end

  test "security regression: valid suffix after invalid UTF-8 remains visible" do
    path_normalized = "pre" <> <<0, 0xFF, 0xFE>> <> "post no such table: memory_relationships"
    diagnostic = Core.child_diagnostic(2, false, path_normalized)

    assert diagnostic["output_bytes"] == byte_size(path_normalized)
    assert diagnostic["output_sha256"] == sha256(path_normalized)

    excerpt = diagnostic["untrusted_diagnostic_output"]
    assert excerpt == "prepost no such table: memory_relationships"
    refute String.contains?(excerpt, <<0>>)
    refute String.contains?(excerpt, <<0xFF>>)
    refute String.contains?(excerpt, <<0xFE>>)
    assert String.valid?(excerpt)
    assert jason_object?(diagnostic)
    refute diagnostic["output_sha256"] == sha256(excerpt)
  end

  test "security regression: failed diagnostic excerpt retains a middle ExUnit failure block" do
    startup = "Running ExUnit with mix...\nSeed: 424242\nMax cases: 8\n"

    noise_before =
      Enum.map_join(1..300, fn i -> "starting line #{i} dependency warmup ok\n" end)

    failure_block =
      "\n\n" <>
        "  1) test security regression keeps the diagnostic (Arbor.Security.GateTest)\n" <>
        "     apps/arbor_security/test/gate_test.exs:42:1\n" <>
        "     code: assert Gate.allow?(forged) == false\n" <>
        "     lhs:  true\n" <>
        "     rhs:  false\n" <>
        "     stacktrace:\n" <>
        "       apps/arbor_security/lib/gate.ex:88: Arbor.Security.Gate.allow?/1\n"

    noise_after = Enum.map_join(1..200, fn i -> "trailing pass line #{i} ok\n" end)

    summary =
      "\nFinished in 1.2 seconds\n12 tests, 1 failure\nRandomized with seed 424242\n"

    raw = startup <> noise_before <> failure_block <> noise_after <> summary

    assert byte_size(raw) > Core.untrusted_diagnostic_output_limit() * 5
    {anchor_offset, _} = :binary.match(raw, "  1) test security regression keeps the diagnostic")

    old_half =
      div(
        Core.untrusted_diagnostic_output_limit() - byte_size(Core.untrusted_omission_marker()),
        2
      )

    assert anchor_offset > old_half
    assert anchor_offset < byte_size(raw) - old_half

    failed = Core.child_diagnostic(1, false, raw)
    assert_failure_aware_exunit_excerpt(failed, raw)

    timed = Core.child_diagnostic(0, true, raw)
    assert_failure_aware_exunit_excerpt(timed, raw)

    success = Core.child_diagnostic(0, false, raw)
    success_excerpt = success["untrusted_diagnostic_output"]
    assert success["output_bytes"] == byte_size(raw)
    assert success["output_sha256"] == sha256(raw)
    refute success["output_sha256"] == sha256(success_excerpt)
    assert String.contains?(success_excerpt, "Seed: 424242")
    assert String.contains?(success_excerpt, "Randomized with seed 424242")
    refute String.contains?(success_excerpt, "Gate.allow?(forged)")
    refute String.contains?(success_excerpt, "Arbor.Security.GateTest")
    assert byte_size(success_excerpt) <= Core.untrusted_diagnostic_output_limit()
    assert String.valid?(success_excerpt)
    assert jason_object?(success)
  end

  test "security regression: failure-aware excerpt keeps a middle anchor when both window edges split UTF-8" do
    # lookback 64 ≡ 1 (mod 3) and middle budget 1512 ≡ 0 (mod 3) match the
    # module attributes. A 3-byte pre-anchor run ending on a character
    # boundary therefore splits both computed middle-window edges.
    lookback = 64
    middle_budget = 1512
    header = "Running ExUnit...\nSeed: 424242\nMax cases: 8\n"
    before = String.duplicate("測", 800)

    failure_block =
      "  1) test utf8 window keeps the diagnostic (Arbor.Security.Utf8WindowTest)\n" <>
        "     apps/arbor_security/test/utf8_window_test.exs:7:1\n" <>
        "     code: assert Gate.allow?(forged) == false\n" <>
        "     lhs:  true\n" <>
        "     rhs:  false\n"

    after_noise = String.duplicate("測", 800)
    footer = "\n12 tests, 1 failure\nRandomized with seed 424242\n"
    raw = header <> before <> failure_block <> after_noise <> footer

    assert rem(lookback, 3) == 1
    assert rem(middle_budget, 3) == 0
    assert rem(byte_size(before), 3) == 0
    {anchor_offset, _} = :binary.match(raw, "  1) test utf8 window keeps the diagnostic")
    raw_middle = binary_part(raw, anchor_offset - lookback, middle_budget)
    refute String.valid?(raw_middle)

    diagnostic = Core.child_diagnostic(1, false, raw)
    excerpt = diagnostic["untrusted_diagnostic_output"]

    assert diagnostic["output_bytes"] == byte_size(raw)
    assert diagnostic["output_sha256"] == sha256(raw)
    refute diagnostic["output_sha256"] == sha256(excerpt)
    assert String.contains?(excerpt, "Gate.allow?(forged)")
    assert String.contains?(excerpt, "Arbor.Security.Utf8WindowTest")
    assert String.contains?(excerpt, "測")
    assert String.valid?(excerpt)
    assert byte_size(excerpt) <= Core.untrusted_diagnostic_output_limit()
    assert jason_object?(diagnostic)
    refute String.contains?(excerpt, <<0xEF, 0xBF, 0xBD>>)
    refute String.contains?(excerpt, <<0>>)
  end

  test "security regression: failed diagnostic excerpt retains compilation-error and uncaught-exception anchors" do
    raw_compile =
      "Compiling apps/foo/lib/foo.ex...\n" <>
        String.duplicate("noise compile line\n", 300) <>
        "== Compilation error in file apps/foo/lib/foo.ex ==\n" <>
        "    ** (CompileError) apps/foo/lib/foo.ex:12: undefined function do_thing/0\n" <>
        String.duplicate("trailing noise compile line\n", 200) <>
        "\n\n** (Mix) Compile error\n"

    compile_diag = Core.child_diagnostic(1, false, raw_compile)
    compile_excerpt = compile_diag["untrusted_diagnostic_output"]
    assert String.contains?(compile_excerpt, "== Compilation error")
    assert String.contains?(compile_excerpt, "CompileError")
    assert String.contains?(compile_excerpt, "do_thing/0")
    assert String.valid?(compile_excerpt)
    assert byte_size(compile_excerpt) <= Core.untrusted_diagnostic_output_limit()
    assert jason_object?(compile_diag)
    assert compile_diag["output_bytes"] == byte_size(raw_compile)
    assert compile_diag["output_sha256"] == sha256(raw_compile)

    raw_exc =
      "Starting task...\n" <>
        String.duplicate("noise exc line\n", 300) <>
        "** (RuntimeError) boom widget failed unexpectedly\n" <>
        "    (foo 0.1.0) lib/foo/runtime.ex:7: Foo.Runtime.run/1\n" <>
        String.duplicate("trailing noise exc line\n", 200)

    exc_diag = Core.child_diagnostic(1, false, raw_exc)
    exc_excerpt = exc_diag["untrusted_diagnostic_output"]
    assert String.contains?(exc_excerpt, "** (RuntimeError) boom widget failed unexpectedly")
    assert String.contains?(exc_excerpt, "Foo.Runtime.run/1")
    assert String.valid?(exc_excerpt)
    assert byte_size(exc_excerpt) <= Core.untrusted_diagnostic_output_limit()
    assert jason_object?(exc_diag)
    assert exc_diag["output_bytes"] == byte_size(raw_exc)
    assert exc_diag["output_sha256"] == sha256(raw_exc)
  end

  test "security regression: failed output without a structural anchor keeps head/tail" do
    raw =
      "HEAD-LINE-START\n" <>
        String.duplicate("noise line without anchor marker\n", 400) <>
        "the assertion failed after a timeout\n" <>
        String.duplicate("more noise line without structure\n", 400) <>
        "TAIL-LINE-END\n"

    diagnostic = Core.child_diagnostic(2, false, raw)
    excerpt = diagnostic["untrusted_diagnostic_output"]

    assert String.contains?(excerpt, "HEAD-LINE-START")
    assert String.contains?(excerpt, "TAIL-LINE-END")
    assert String.contains?(excerpt, Core.untrusted_omission_marker())
    refute String.contains?(excerpt, "the assertion failed after a timeout")
    assert String.valid?(excerpt)
    assert byte_size(excerpt) <= Core.untrusted_diagnostic_output_limit()
    assert jason_object?(diagnostic)
    assert diagnostic["output_bytes"] == byte_size(raw)
    assert diagnostic["output_sha256"] == sha256(raw)
  end

  defp assert_failure_aware_exunit_excerpt(diagnostic, raw) do
    excerpt = diagnostic["untrusted_diagnostic_output"]
    assert diagnostic["output_bytes"] == byte_size(raw)
    assert diagnostic["output_sha256"] == sha256(raw)
    refute diagnostic["output_sha256"] == sha256(excerpt)
    assert String.contains?(excerpt, "Seed: 424242")
    assert String.contains?(excerpt, "Gate.allow?(forged)")
    assert String.contains?(excerpt, "Arbor.Security.GateTest")
    assert String.contains?(excerpt, "lhs:  true")
    assert String.contains?(excerpt, "12 tests, 1 failure")
    assert String.contains?(excerpt, "Randomized with seed 424242")
    assert byte_size(excerpt) <= Core.untrusted_diagnostic_output_limit()
    assert String.valid?(excerpt)
    refute String.contains?(excerpt, <<0>>)
    assert jason_object?(diagnostic)
    assert length(String.split(excerpt, Core.untrusted_omission_marker())) == 3
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
      "output_sha256" => String.duplicate("a", 64),
      "untrusted_diagnostic_output" => ""
    }
  end

  defp sha256(value) when is_binary(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end

  defp jason_object?(map) when is_map(map) do
    encoded = Jason.encode!(map)
    is_binary(encoded) and String.valid?(encoded)
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
