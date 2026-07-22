defmodule Arbor.Orchestrator.CodingPlan.CandidateVerificationCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.ValidationCapacityHandoff
  alias Arbor.Orchestrator.CodingPlan.{CandidateVerificationCore, Profiles, ValidationProgram}

  @moduletag :fast

  @sha1 String.duplicate("a", 40)
  @sha256 String.duplicate("b", 64)
  @base_oid String.duplicate("c", 40)
  @candidate_commit String.duplicate("d", 40)
  @digest String.duplicate("e", 64)
  @other_digest String.duplicate("f", 64)
  @observed_at "2026-07-22T12:00:00.000Z"

  @gate_ids %{
    "default" => ["coding.validation.default.compile"],
    "cross_app" => [
      "coding.validation.cross_app.compile",
      "coding.validation.cross_app.xref",
      "coding.validation.cross_app.test_compile",
      "coding.validation.cross_app.tests"
    ],
    "security_regression" => [
      "coding.validation.security_regression.attestation",
      "coding.validation.security_regression.candidate",
      "coding.validation.security_regression.base"
    ]
  }

  test "all executable profiles produce passed canonical reports with stable ordered gates" do
    for {profile, result} <- [
          {"default", default_result()},
          {"cross_app", cross_result()},
          {"security_regression", security_result("security_regression_validated")}
        ] do
      assert {:ok, report} = verify(profile, result)
      assert report["version"] == 1
      assert report["status"] == "passed"
      assert report["profile"] == profile
      assert report["candidate_ref"] == "git-tree:" <> @sha1
      assert report["observed_at"] == @observed_at
      assert String.match?(report["evidence_ref"], ~r/\Asha256:[0-9a-f]{64}\z/)
      assert Enum.map(report["diagnostics"], & &1["gate_id"]) == @gate_ids[profile]
      assert Enum.all?(report["diagnostics"], &(&1["decision"] == "passed"))
      assert Enum.all?(report["diagnostics"], &(&1["evidence_ref"] == report["evidence_ref"]))
    end
  end

  test "canonical validator failures are failed while every nonpassing diagnostic is blocked" do
    cases = [
      {"default", default_result(exit_code: 1), "compile_failed"},
      {"cross_app", cross_failure(:compile), "compile_failed"},
      {"cross_app", cross_failure(:xref), "xref_failed"},
      {"cross_app", cross_failure(:test_compile), "test_compile_failed"},
      {"cross_app", cross_failure(:test), "tests_failed"},
      {"security_regression", security_result("candidate_tests_failed"),
       "candidate_tests_failed"},
      {"security_regression", security_result("base_tests_passed"), "base_tests_passed"}
    ]

    for {profile, result, failure_code} <- cases do
      assert {:ok, report} = verify(profile, result)
      assert report["status"] == "failed"
      assert failure_code in Enum.map(report["diagnostics"], & &1["code"])

      assert Enum.all?(report["diagnostics"], fn diagnostic ->
               diagnostic["decision"] in ["passed", "blocked"]
             end)

      refute Enum.any?(report["diagnostics"], &(&1["decision"] == "failed"))
    end
  end

  test "cross-app compile failure is coded on the compile gate itself in stable order" do
    assert {:ok, report} = verify("cross_app", cross_failure(:compile))

    assert Enum.map(report["diagnostics"], &{&1["gate_id"], &1["code"]}) == [
             {"coding.validation.cross_app.compile", "compile_failed"},
             {"coding.validation.cross_app.xref", "compile_failed"},
             {"coding.validation.cross_app.test_compile", "compile_failed"},
             {"coding.validation.cross_app.tests", "compile_failed"}
           ]
  end

  test "capacity, timeout, and closed security setup reasons are blocked" do
    cases = [
      {"cross_app", cross_capacity_result(), "validation_capacity_exceeded"},
      {"cross_app", cross_timeout_result(), "tests_timed_out"},
      {"security_regression", security_result("candidate_setup_failed"),
       "candidate_setup_failed"},
      {"security_regression", security_result("candidate_source_changed"),
       "candidate_source_changed"},
      {"security_regression", security_result("base_setup_failed"), "base_setup_failed"},
      {"security_regression", security_result("base_snapshot_failed"), "base_snapshot_failed"}
    ]

    for {profile, result, code} <- cases do
      assert {:ok, report} = verify(profile, result)
      assert report["status"] == "blocked"
      assert code in Enum.map(report["diagnostics"], & &1["code"])
      assert report["evidence_ref"] =~ "sha256:"
    end
  end

  test "capacity handoff is closed, bounded evidence and malformed handoffs fail closed" do
    result = cross_capacity_result()
    assert {:ok, report} = verify("cross_app", result)
    assert report["status"] == "blocked"

    tampered = put_in(result, [:test, "capacity_handoff", "required_budget_ms"], 2_000)
    assert_invalid_evidence("cross_app", tampered)

    extra = put_in(result, [:test, "capacity_handoff", "authority"], "forbidden")
    assert_invalid_evidence("cross_app", extra)
  end

  test "atom producer returns and recursively string-keyed Engine projections digest identically" do
    for {profile, result} <- [
          {"default", default_result()},
          {"cross_app", cross_result()},
          {"security_regression", security_result("security_regression_validated")}
        ] do
      assert {:ok, atom_report} = verify(profile, result)
      assert {:ok, string_report} = verify(profile, stringify_json(result))
      assert atom_report == string_report
    end
  end

  test "raw stdout, stderr, feedback, excerpts, and feedback_json never enter the digest or report" do
    original = default_result()

    changed = %{
      original
      | stdout: "different stdout",
        stderr: "different stderr",
        feedback_json: "different ignored feedback json",
        feedback: %{
          original.feedback
          | "stdout_excerpt" => "different excerpt",
            "stderr_excerpt" => "another excerpt"
        }
    }

    assert {:ok, original_report} = verify("default", original)
    assert {:ok, changed_report} = verify("default", changed)
    assert original_report == changed_report

    cross = cross_result()

    changed_cross =
      cross
      |> put_in([:compile, "stdout_excerpt"], "different")
      |> Map.put(:feedback_json, "different ignored feedback json")

    assert {:ok, cross_report} = verify("cross_app", cross)
    assert {:ok, changed_cross_report} = verify("cross_app", changed_cross)
    assert cross_report == changed_cross_report

    security = security_result("security_regression_validated")

    changed_security =
      security
      |> Map.put(:feedback_json, "different ignored feedback json")

    assert {:ok, security_report} = verify("security_regression", security)
    assert {:ok, changed_security_report} = verify("security_regression", changed_security)
    assert security_report == changed_security_report
  end

  test "digest is deterministic and sensitive to accepted structured evidence" do
    result = cross_result()
    assert {:ok, first} = verify("cross_app", result)
    assert {:ok, second} = verify("cross_app", result)
    assert first["evidence_ref"] == second["evidence_ref"]

    failed = cross_failure(:test)
    assert {:ok, failed_report} = verify("cross_app", failed)
    refute first["evidence_ref"] == failed_report["evidence_ref"]
  end

  test "accepted hashes, scope, heads, and diagnostic execution facts bind evidence_ref" do
    default = default_result()

    default_variants = [
      Map.put(default, :validated_head, @base_oid),
      put_in(default, [:feedback, "stdout_sha256"], @other_digest),
      put_in(default, [:feedback, "stdout_truncated"], true)
    ]

    assert_evidence_changes("default", default, default_variants)

    cross = cross_result()

    changed_scope =
      cross
      |> Map.put(:base_commit, @candidate_commit)
      |> Map.put(:validated_head, @base_oid)
      |> Map.put(:changed_files, ["apps/alpha/lib/alpha.ex", "apps/beta/lib/beta.ex"])
      |> Map.put(:changed_apps, ["alpha", "beta"])
      |> Map.put(:affected_apps, ["alpha", "beta"])
      |> Map.put(:test_paths, ["apps/alpha/test", "apps/beta/test"])
      |> Map.put(:root_wide, true)

    cross_variants = [
      changed_scope,
      put_in(cross, [:compile, "stdout_sha256"], @other_digest),
      put_in(cross, [:test, "stderr_truncated"], true)
    ]

    assert_evidence_changes("cross_app", cross, cross_variants)

    security = security_result("security_regression_validated")

    changed_diagnostic =
      security
      |> put_in([:diagnostics, :candidate, "output_bytes"], 13)
      |> put_in([:diagnostics, :candidate, "output_sha256"], @other_digest)

    assert_evidence_changes("security_regression", security, [changed_diagnostic])
  end

  test "candidate tree drift blocks every profile at its stable gates" do
    for {profile, result} <- [
          {"default", Map.put(default_result(), :validated_tree_oid, @sha256)},
          {"cross_app", Map.put(cross_result(), :validated_tree_oid, @sha256)},
          {"security_regression",
           Map.put(
             security_result("security_regression_validated"),
             :attested_candidate_tree_oid,
             @sha256
           )}
        ] do
      assert {:ok, report} = verify(profile, result)
      assert report["status"] == "blocked"
      assert Enum.map(report["diagnostics"], & &1["gate_id"]) == @gate_ids[profile]
      assert Enum.all?(report["diagnostics"], &(&1["code"] == "candidate_state_drifted"))
      assert report["evidence_ref"] =~ "sha256:"
    end
  end

  test "malformed, extra, mixed-key, inconsistent, and oversized evidence fails closed" do
    default = default_result()
    cross = cross_result()
    security = security_result("security_regression_validated")

    cases = [
      {"default", %{passed: true, exit_code: 0, validated_tree_oid: @sha1}},
      {"default", Map.put(default, :extra, true)},
      {"default", default |> Map.delete(:passed) |> Map.put("passed", true)},
      {"default", Map.put(default, :passed, false)},
      {"default", Map.put(default, :path, String.duplicate("p", 4_097))},
      {"default", put_in(default, [:feedback, "passed"], "true")},
      {"cross_app", Map.put(cross, :extra, true)},
      {"cross_app", put_in(cross, [:compile, "passed"], "true")},
      {"cross_app", put_in(cross, [:xref, "reason"], "convenient_reason")},
      {"cross_app", Map.put(cross, :changed_files, Enum.map(1..2_001, &"file#{&1}"))},
      {"cross_app", Map.put(cross, :changed_files, ["z.ex", "a.ex"])},
      {"cross_app", Map.put(cross, :changed_apps, ["alpha", "alpha"])},
      {"security_regression", Map.put(security, :reason, "arbitrary_failure")},
      {"security_regression", put_in(security, [:candidate, :executed], "1")},
      {"security_regression", put_in(security, [:candidate, :passed], 2)},
      {"security_regression", put_in(security, [:diagnostics, :candidate, "exit_code"], 1)},
      {"security_regression", Map.put(security, :source_hashes, [%{path: "test/x.exs"}])},
      {"security_regression", Map.put(security, :extra, true)}
    ]

    for {profile, result} <- cases do
      assert_invalid_evidence(profile, result)
    end
  end

  test "security attestation arrays and digest bindings must agree exactly" do
    result = security_result("security_regression_validated")

    assert_invalid_evidence(
      "security_regression",
      put_in(result, [:attested_selected_tests, Access.at(0), :blob_sha256], @digest)
    )

    assert_invalid_evidence(
      "security_regression",
      Map.put(result, :attested_base_commit, @candidate_commit)
    )

    assert_invalid_evidence(
      "security_regression",
      Map.put(result, :review_attestation_digest, "SHA256:" <> @digest)
    )

    sorted = put_security_tests(result, ["test/a_test.exs", "test/b_test.exs"])
    assert {:ok, %{"status" => "passed"}} = verify("security_regression", sorted)

    reversed = put_security_tests(result, ["test/b_test.exs", "test/a_test.exs"])
    assert_invalid_evidence("security_regression", reversed)
  end

  test "accepts only exact full SHA-1 or SHA-256 candidate OIDs" do
    for oid <- [@sha1, @sha256] do
      result = Map.put(default_result(), :validated_tree_oid, oid)
      assert {:ok, report} = verify("default", result, oid)
      assert report["candidate_ref"] == "git-tree:" <> oid
    end

    for invalid <- [String.duplicate("a", 39), String.duplicate("a", 41), String.upcase(@sha1)] do
      assert {:error, :invalid_candidate_tree_oid} =
               CandidateVerificationCore.verify(
                 program!("default"),
                 invalid,
                 default_result(),
                 @observed_at
               )
    end
  end

  test "validates the closed program and injected timestamp before adapting evidence" do
    invalid_program = Map.put(program!("default"), "result_adapter", "cross_app_v1")

    assert {:error, :invalid_validation_program} =
             CandidateVerificationCore.verify(
               invalid_program,
               @sha1,
               default_result(),
               @observed_at
             )

    assert {:error, :invalid_observed_at} =
             CandidateVerificationCore.verify(
               program!("default"),
               @sha1,
               default_result(),
               "not-a-timestamp"
             )
  end

  defp verify(profile, result, oid \\ @sha1) do
    CandidateVerificationCore.verify(program!(profile), oid, result, @observed_at)
  end

  defp assert_invalid_evidence(profile, result) do
    assert {:ok, report} = verify(profile, result)
    assert report["status"] == "blocked"
    assert Enum.map(report["diagnostics"], & &1["gate_id"]) == @gate_ids[profile]
    assert Enum.all?(report["diagnostics"], &(&1["code"] == "validation_evidence_invalid"))
    refute Map.has_key?(report, "evidence_ref")
  end

  defp assert_evidence_changes(profile, original, variants) do
    assert {:ok, original_report} = verify(profile, original)

    for variant <- variants do
      assert {:ok, variant_report} = verify(profile, variant)
      refute variant_report["evidence_ref"] == original_report["evidence_ref"]
    end
  end

  defp program!(profile_id) do
    {:ok, profile} = Profiles.fetch_executable(profile_id)

    {:ok, program} =
      ValidationProgram.build(profile["validation_strategy"], %{"wall_clock_ms" => 900_000})

    program
  end

  defp default_result(opts \\ []) do
    exit_code = Keyword.get(opts, :exit_code, 0)
    passed = exit_code == 0

    %{
      path: "/owner/worktree",
      exit_code: exit_code,
      passed: passed,
      stdout: "compile output",
      stderr: "",
      feedback: raw_feedback(passed, exit_code),
      feedback_json: "ignored feedback json",
      validated_tree_oid: @sha1,
      validated_head: @candidate_commit
    }
  end

  defp raw_feedback(passed, exit_code) do
    %{
      "exit_code" => exit_code,
      "passed" => passed,
      "stdout_excerpt" => "compile output",
      "stderr_excerpt" => "",
      "stdout_truncated" => false,
      "stderr_truncated" => false,
      "stdout_sha256" => @digest,
      "stderr_sha256" => @other_digest
    }
  end

  defp cross_result do
    %{
      passed: true,
      reason: "cross_app_validated",
      base_commit: @base_oid,
      changed_files: ["apps/alpha/lib/alpha.ex"],
      changed_apps: ["alpha"],
      affected_apps: ["alpha"],
      test_paths: ["apps/alpha/test"],
      root_wide: false,
      compile: cross_check(),
      xref: cross_check(),
      test_compile: cross_check(),
      test: cross_check(),
      validated_tree_oid: @sha1,
      validated_head: @candidate_commit,
      feedback_json: "ignored feedback json"
    }
  end

  defp cross_failure(:compile) do
    cross_result()
    |> Map.merge(%{
      passed: false,
      reason: "compile_failed",
      compile: cross_check(passed: false, exit_code: 1),
      xref: skipped_check("compile_failed"),
      test_compile: skipped_check("compile_failed"),
      test: skipped_check("compile_failed")
    })
  end

  defp cross_failure(:xref) do
    cross_result()
    |> Map.merge(%{
      passed: false,
      reason: "xref_failed",
      xref: cross_check(passed: false, exit_code: 1, reason: "xref_failed"),
      test_compile: skipped_check("xref_failed"),
      test: skipped_check("xref_failed")
    })
  end

  defp cross_failure(:test_compile) do
    cross_result()
    |> Map.merge(%{
      passed: false,
      reason: "test_compile_failed",
      test_compile: cross_check(passed: false, exit_code: 1, reason: "test_compile_failed"),
      test: skipped_check("test_compile_failed")
    })
  end

  defp cross_failure(:test) do
    cross_result()
    |> Map.merge(%{
      passed: false,
      reason: "tests_failed",
      test: cross_check(passed: false, exit_code: 1, reason: "tests_failed")
    })
  end

  defp cross_timeout_result do
    cross_result()
    |> Map.merge(%{
      passed: false,
      reason: "tests_timed_out",
      test: cross_check(passed: false, exit_code: nil, reason: "tests_timed_out")
    })
  end

  defp cross_capacity_result do
    cross_result()
    |> Map.merge(%{
      passed: false,
      reason: "validation_capacity_exceeded",
      test:
        cross_check(passed: false, exit_code: nil, reason: "validation_capacity_exceeded")
        |> Map.put("capacity_handoff", capacity_handoff())
    })
  end

  defp cross_check(opts \\ []) do
    %{
      "status" => Keyword.get(opts, :status, "completed"),
      "passed" => Keyword.get(opts, :passed, true),
      "exit_code" => Keyword.get(opts, :exit_code, 0),
      "reason" => Keyword.get(opts, :reason),
      "stdout_excerpt" => "ignored output",
      "stderr_excerpt" => "",
      "stdout_truncated" => false,
      "stderr_truncated" => false,
      "stdout_sha256" => @digest,
      "stderr_sha256" => @other_digest
    }
  end

  defp skipped_check(reason),
    do: cross_check(status: "skipped", passed: false, exit_code: nil, reason: reason)

  defp capacity_handoff do
    inventory = @digest
    label = "batch-1-of-1-n1-#{inventory}"

    batch = %{
      "index" => 1,
      "total" => 1,
      "count" => 1,
      "label" => label,
      "inventory_sha256" => inventory
    }

    {:ok, plan_digest} = ValidationCapacityHandoff.ordered_plan_digest([batch])

    {:ok, handoff} =
      ValidationCapacityHandoff.normalize(%{
        "schema_version" => ValidationCapacityHandoff.schema_version(),
        "phase" => "structural",
        "available_budget_ms" => 0,
        "per_batch_budget_ms" => 1_000,
        "required_budget_ms" => 1_000,
        "completed_batch_count" => 0,
        "completed_file_count" => 0,
        "unstarted_batch_count" => 1,
        "unstarted_file_count" => 1,
        "total_batch_count" => 1,
        "total_file_count" => 1,
        "ordered_plan_sha256" => plan_digest,
        "unstarted_batches" => [batch]
      })

    handoff
  end

  defp security_result(reason) do
    {candidate, base} = security_legs(reason)
    passed = reason == "security_regression_validated"
    path = "test/security_regression_test.exs"

    %{
      passed: passed,
      reason: reason,
      base_commit: @base_oid,
      candidate_fingerprint: @digest,
      test_paths: [path],
      source_hashes: [%{path: path, sha256: @other_digest}],
      candidate: candidate,
      base: base,
      diagnostics: %{
        candidate: security_diagnostic(candidate, :candidate),
        base: security_diagnostic(base, :base)
      },
      evidence_type: "reviewed_regression_evidence",
      attested_base_commit: @base_oid,
      attested_candidate_commit: @candidate_commit,
      attested_candidate_tree_oid: @sha1,
      attested_diff_sha256: @digest,
      attested_selected_tests: [%{path: path, blob_sha256: @other_digest}],
      review_attestation_digest: @digest,
      council_decision_digest: @other_digest,
      feedback_json: "ignored feedback json"
    }
  end

  defp security_legs("security_regression_validated"),
    do: {candidate_pass_leg(), base_fail_leg()}

  defp security_legs("candidate_source_changed"),
    do: {%{candidate_pass_leg() | status: "source_changed", completed: false}, not_run_leg()}

  defp security_legs("candidate_timeout"),
    do: {%{candidate_pass_leg() | timed_out: true}, not_run_leg()}

  defp security_legs("candidate_setup_failed") do
    candidate = %{candidate_pass_leg() | executed: 0, passed: 0, setup_failures: 1, invalid: 1}
    {candidate, not_run_leg()}
  end

  defp security_legs("candidate_tests_failed") do
    candidate = %{candidate_pass_leg() | exit_code: 1, passed: 0, test_failures: 1}
    {candidate, not_run_leg()}
  end

  defp security_legs("base_tests_passed") do
    base = %{candidate_pass_leg() | status: "completed", completed: true}
    {candidate_pass_leg(), base}
  end

  defp security_legs("base_setup_failed") do
    base = %{base_fail_leg() | executed: 0, test_failures: 0, setup_failures: 1, invalid: 1}
    {candidate_pass_leg(), base}
  end

  defp security_legs("base_snapshot_failed") do
    base = %{not_run_leg() | status: "snapshot_failed"}
    {candidate_pass_leg(), base}
  end

  defp candidate_pass_leg do
    %{
      completed: true,
      status: "completed",
      exit_code: 0,
      timed_out: false,
      executed: 1,
      passed: 1,
      test_failures: 0,
      setup_failures: 0,
      skipped: 0,
      excluded: 0,
      invalid: 0
    }
  end

  defp base_fail_leg do
    %{
      candidate_pass_leg()
      | exit_code: 1,
        passed: 0,
        test_failures: 1
    }
  end

  defp not_run_leg do
    %{
      candidate_pass_leg()
      | completed: false,
        status: "not_run",
        exit_code: nil,
        executed: 0,
        passed: 0
    }
  end

  defp security_diagnostic(leg, kind) do
    empty? =
      case {kind, leg.status} do
        {:candidate, status} when status in ["source_changed", "helper_missing"] ->
          true

        {:base, status}
        when status in ["helper_missing", "snapshot_failed", "overlay_failed", "not_run"] ->
          true

        _other ->
          false
      end

    if empty? do
      %{}
    else
      %{
        "exit_code" => leg.exit_code,
        "timed_out" => leg.timed_out,
        "output_bytes" => 12,
        "output_sha256" => @digest
      }
    end
  end

  defp put_security_tests(result, paths) do
    result
    |> Map.put(:test_paths, paths)
    |> Map.put(:source_hashes, Enum.map(paths, &%{path: &1, sha256: @other_digest}))
    |> Map.put(
      :attested_selected_tests,
      Enum.map(paths, &%{path: &1, blob_sha256: @other_digest})
    )
  end

  defp stringify_json(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, stringify_json(value)}
    end)
  end

  defp stringify_json(list) when is_list(list), do: Enum.map(list, &stringify_json/1)
  defp stringify_json(value), do: value
end
