defmodule Arbor.Orchestrator.CodingPlan.CandidateVerificationCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions
  alias Arbor.Actions.Coding.ContractChange.Core
  alias Arbor.Contracts.Coding.ValidationCapacityHandoff

  alias Arbor.Orchestrator.CodingPlan.{
    CandidateVerificationCore,
    Profiles,
    ValidationCapacityTerminal,
    ValidationProgram
  }

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
    ],
    "contract_change" => [
      "coding.validation.contract_change.preflight",
      "coding.validation.contract_change.tests"
    ]
  }

  test "all executable profiles produce passed canonical reports with stable ordered gates" do
    for {profile, result} <- [
          {"default", default_result()},
          {"cross_app", cross_result()},
          {"security_regression", security_result("security_regression_validated")},
          {"contract_change", contract_result()}
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
      {"security_regression", security_result("base_tests_passed"), "base_tests_passed"},
      {"contract_change", contract_failure(:preflight), "preflight_failed"},
      {"contract_change", contract_failure(:test), "tests_failed"},
      {"contract_change", contract_surface_missing_result(), "contract_surface_missing"}
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
      {"default", default_capacity_result(), "validation_capacity_exceeded"},
      {"cross_app", cross_capacity_result(), "validation_capacity_exceeded"},
      {"cross_app", cross_timeout_result(), "tests_timed_out"},
      {"contract_change", contract_capacity_result(:test), "validation_capacity_exceeded"},
      {"contract_change", contract_capacity_result(:preflight), "validation_capacity_exceeded"},
      {"security_regression", security_result("validation_capacity_exceeded"),
       "validation_capacity_exceeded"},
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

  test "default profile admits exit-zero containment failure as distinct blocked assessment" do
    result = default_containment_result()

    assert result.exit_code == 0
    assert result.passed == false
    assert result.reason == "validation_containment_failure"
    assert result.termination["containment_failure"] == true
    assert map_size(result.termination) == 5

    assert {:ok, report} = verify("default", result)
    assert report["status"] == "blocked"
    assert "validation_containment_failure" in Enum.map(report["diagnostics"], & &1["code"])
    refute "validation_capacity_exceeded" in Enum.map(report["diagnostics"], & &1["code"])
    refute "compile_failed" in Enum.map(report["diagnostics"], & &1["code"])
    assert report["evidence_ref"] =~ "sha256:"

    # Four-key capacity envelope must not be accepted as containment evidence.
    forged_capacity_shape =
      Map.put(result, :termination, %{
        "timed_out" => false,
        "killed" => true,
        "output_limit_exceeded" => false,
        "cancelled" => false
      })

    assert {:ok, invalid} = verify("default", forged_capacity_shape)
    assert invalid["status"] == "blocked"
    assert "validation_evidence_invalid" in Enum.map(invalid["diagnostics"], & &1["code"])

    # containment_failure false is rejected even with five keys.
    forged_flag =
      Map.put(result, :termination, %{
        "timed_out" => false,
        "killed" => true,
        "output_limit_exceeded" => false,
        "cancelled" => false,
        "containment_failure" => false
      })

    assert {:ok, invalid_flag} = verify("default", forged_flag)
    assert "validation_evidence_invalid" in Enum.map(invalid_flag["diagnostics"], & &1["code"])
  end

  test "security regression capacity rejects forged and ambiguous evidence" do
    good = security_result("validation_capacity_exceeded")
    assert {:ok, report} = verify("security_regression", good)
    assert report["status"] == "blocked"

    # Missing termination envelope.
    assert {:ok, invalid} =
             verify("security_regression", Map.put(good, :termination, nil))

    assert invalid["status"] == "blocked"
    assert "validation_evidence_invalid" in Enum.map(invalid["diagnostics"], & &1["code"])

    # timed_out false in termination.
    forged_termination =
      Map.put(good, :termination, %{
        "timed_out" => false,
        "killed" => true,
        "output_limit_exceeded" => false,
        "cancelled" => false
      })

    assert {:ok, killed_only} = verify("security_regression", forged_termination)
    assert "validation_evidence_invalid" in Enum.map(killed_only["diagnostics"], & &1["code"])

    # Leg/diagnostic inconsistency (post-child gap class).
    inconsistent =
      good
      |> put_in([:diagnostics, :candidate, "timed_out"], false)

    assert {:ok, drift} = verify("security_regression", inconsistent)
    assert "validation_evidence_invalid" in Enum.map(drift["diagnostics"], & &1["code"])

    # Exit 137 alone is ordinary domain failure, not capacity.
    exit_only =
      security_result("candidate_tests_failed")
      |> put_in([:candidate, :exit_code], 137)
      |> put_in([:diagnostics, :candidate, "exit_code"], 137)

    assert exit_only.candidate.exit_code == 137
    assert exit_only.diagnostics.candidate["exit_code"] == 137
    assert exit_only.candidate.timed_out == false
    assert exit_only.termination == nil

    assert {:ok, ordinary} = verify("security_regression", exit_only)
    assert ordinary["status"] == "failed"
    assert "candidate_tests_failed" in Enum.map(ordinary["diagnostics"], & &1["code"])
    refute "validation_capacity_exceeded" in Enum.map(ordinary["diagnostics"], & &1["code"])

    four_key =
      good
      |> update_in([:diagnostics, :candidate], &Map.delete(&1, "untrusted_diagnostic_output"))

    assert {:ok, missing_excerpt} = verify("security_regression", four_key)
    assert "validation_evidence_invalid" in Enum.map(missing_excerpt["diagnostics"], & &1["code"])
  end

  test "contract_change timeout and one-handoff capacity evidence is blocked" do
    assert_invalid_evidence("contract_change", contract_timeout_result())

    assert {:ok, test_capacity} = verify("contract_change", contract_capacity_result(:test))
    assert test_capacity["status"] == "blocked"

    assert "validation_capacity_exceeded" in Enum.map(test_capacity["diagnostics"], & &1["code"])

    assert {:ok, preflight_capacity} =
             verify("contract_change", contract_capacity_result(:preflight))

    assert preflight_capacity["status"] == "blocked"

    both = contract_capacity_result(:test)

    both =
      Map.put(
        both,
        :preflight,
        Map.put(both.preflight, "capacity_handoff", contract_capacity_handoff(:preflight))
      )

    assert_invalid_evidence("contract_change", both)
  end

  test "security regression: contract_change rejects preflight_timed_out and tests_timed_out speculative forms" do
    assert_invalid_evidence("contract_change", contract_timeout_result())
    assert_invalid_evidence("contract_change", contract_preflight_timeout_result())
  end

  test "security regression: ContractChange and default Mix.Compile containment producers match terminal admission" do
    assert {:ok, default_report} = verify("default", default_containment_result())
    assert default_report["status"] == "blocked"

    assert "validation_containment_failure" in Enum.map(
             default_report["diagnostics"],
             & &1["code"]
           )

    default_terminal = %{
      "status" => "validation_failed",
      "canonical_status" => "validation_failed",
      "validation" => [
        %{
          "reason" => "validation_containment_failure",
          "passed" => false,
          "exit_code" => 0,
          "termination" => containment_termination()
        }
      ]
    }

    assert {:ok, normalized_default} =
             ValidationCapacityTerminal.normalize_result(default_terminal, :terminal)

    assert :ok = ValidationCapacityTerminal.validate_consistency(normalized_default, :terminal)

    {:ok, check} =
      Core.check_from_projection(
        Core.feedback_from_result(%{exit_code: 0, stdout: "ok", stderr: ""}),
        %{
          exit_code: 0,
          passed: false,
          reason: "validation_containment_failure",
          termination: containment_termination()
        },
        :preflight,
        %{
          completed: [],
          current: Core.preflight_batch(Core.inventory_sha256(Core.preflight_argv())),
          unstarted: [
            Core.tests_batch(
              1,
              Core.inventory_sha256(["apps/arbor_kernel/test/arbor/contracts/admission_test.exs"])
            )
          ],
          per_batch_budget_ms: 10_000
        }
      )

    evidence =
      Core.show(%{
        changed_files: ["apps/arbor_kernel/lib/arbor/contracts/foo.ex"],
        test_paths: ["apps/arbor_kernel/test/arbor/contracts/admission_test.exs"],
        checks: %{
          preflight: check,
          test: Core.skipped_check("validation_containment_failure")
        },
        base_commit: @base_oid
      })

    cv_result =
      Map.merge(evidence, %{
        validated_tree_oid: @sha1,
        validated_head: @candidate_commit,
        feedback_json: "ignored feedback json"
      })

    assert {:ok, contract_report} = verify("contract_change", cv_result)
    assert contract_report["status"] == "blocked"

    assert "validation_containment_failure" in Enum.map(
             contract_report["diagnostics"],
             & &1["code"]
           )

    contract_terminal = %{
      "status" => "validation_failed",
      "canonical_status" => "validation_failed",
      "validation" => [
        %{
          "passed" => evidence.passed,
          "reason" => evidence.reason,
          "preflight" => evidence.preflight,
          "test" => evidence.test
        }
      ]
    }

    assert {:ok, normalized_contract} =
             ValidationCapacityTerminal.normalize_result(contract_terminal, :terminal)

    assert :ok =
             ValidationCapacityTerminal.validate_consistency(normalized_contract, :terminal)
  end

  test "security regression: contract_change contradictory containment envelopes are invalid evidence" do
    report_passed = Map.put(contract_containment_result(:preflight), :passed, true)
    assert_invalid_evidence("contract_change", report_passed)
  end

  test "contract_change exit-zero containment is blocked with a five-key envelope" do
    result = contract_containment_result(:preflight)
    assert result.preflight["exit_code"] == 0
    assert result.preflight["termination"]["containment_failure"] == true

    assert {:ok, report} = verify("contract_change", result)
    assert report["status"] == "blocked"
    assert "validation_containment_failure" in Enum.map(report["diagnostics"], & &1["code"])
    refute "validation_capacity_exceeded" in Enum.map(report["diagnostics"], & &1["code"])

    four_key =
      put_in(result.preflight["termination"], %{
        "timed_out" => false,
        "killed" => true,
        "output_limit_exceeded" => false,
        "cancelled" => false
      })

    assert_invalid_evidence("contract_change", four_key)

    false_flag =
      put_in(result.preflight["termination"]["containment_failure"], false)

    assert_invalid_evidence("contract_change", false_flag)
  end

  test "contract_change interrupted capacity is blocked and forged extras fail closed" do
    assert {:ok, preflight} =
             verify("contract_change", contract_interrupted_capacity_result(:preflight))

    assert preflight["status"] == "blocked"
    assert "validation_capacity_exceeded" in Enum.map(preflight["diagnostics"], & &1["code"])

    assert {:ok, tests} = verify("contract_change", contract_interrupted_capacity_result(:test))
    assert tests["status"] == "blocked"
    assert "validation_capacity_exceeded" in Enum.map(tests["diagnostics"], & &1["code"])

    mixed = contract_containment_result(:preflight)

    mixed =
      put_in(
        mixed.preflight["capacity_handoff"],
        contract_capacity_handoff(:preflight)
      )

    assert_invalid_evidence("contract_change", mixed)

    passed_with_extra =
      contract_result()
      |> Map.put(:preflight, Map.put(cross_check(), "termination", containment_termination()))

    assert_invalid_evidence("contract_change", passed_with_extra)

    for version <- [1, 2] do
      historical = contract_capacity_result(:test)

      historical =
        put_in(historical.test["capacity_handoff"], historical_capacity_handoff(version))

      assert_invalid_evidence("contract_change", historical)
    end
  end

  test "security regression: contract_change contradictory capacity envelopes are invalid evidence" do
    report_passed = Map.put(contract_capacity_result(:preflight), :passed, true)
    assert_invalid_evidence("contract_change", report_passed)

    check_passed =
      contract_capacity_result(:preflight)
      |> put_in([:preflight, "passed"], true)

    assert_invalid_evidence("contract_change", check_passed)

    test_passed =
      contract_capacity_result(:test)
      |> put_in([:test, "passed"], true)

    assert_invalid_evidence("contract_change", test_passed)

    skipped_exit =
      contract_capacity_result(:preflight)
      |> put_in([:test, "exit_code"], 0)

    assert_invalid_evidence("contract_change", skipped_exit)

    paths =
      Enum.map(1..80, fn i ->
        n = String.pad_leading(Integer.to_string(i), 3, "0")
        "apps/arbor_kernel/test/arbor/contracts/file_#{n}_test.exs"
      end)

    wide = Map.put(contract_capacity_result(:test), :test_paths, paths)
    assert {:ok, report} = verify("contract_change", wide)
    assert report["status"] == "blocked"
    assert "validation_capacity_exceeded" in Enum.map(report["diagnostics"], & &1["code"])

    wide_pass = Map.put(contract_result(), :test_paths, paths)
    assert {:ok, passed} = verify("contract_change", wide_pass)
    assert passed["status"] == "passed"
  end

  test "security regression: producer-valid max ContractChange inventories remain consumer-valid under the 1 MiB feedback ceiling" do
    # Parent b2a6fc8df326945881891e5162edd7cc94cbc5e5 copies Core.show/1 inventories
    # into feedback_json, so a 2,000×1,024 + 256×1,024 producer-valid result exceeds
    # CandidateVerificationCore's 1 MiB ceiling and adapt_contract_change/1 yields
    # validation_evidence_invalid. Checkpoint e7ea50333f4405802005696aaaa9ead2d68ad4c6
    # already projects that feedback_json, but still fails here: evidence_ref/1 encodes
    # the raw inventories and exceeds the 256,000-byte canonical evidence ceiling.
    # This candidate closes the second boundary with compact inventory summaries.
    files = Enum.map(1..2_000, &max_contract_changed_path/1)
    tests = Enum.map(1..256, &max_contract_test_path/1)
    assert byte_size(hd(files)) == 1_024
    assert byte_size(hd(tests)) == 1_024

    assert {:ok, inventories} = Core.admit_transport_inventories(files, tests)
    passed_check = Core.completed_check(%{"passed" => true, "exit_code" => 0})

    evidence =
      Core.show(%{
        changed_files: inventories.changed_files,
        test_paths: inventories.test_paths,
        checks: %{preflight: passed_check, test: passed_check},
        base_commit: @base_oid
      })
      |> Map.put(:validated_tree_oid, @sha1)
      |> Map.put(:validated_head, @candidate_commit)

    assert evidence.changed_files == inventories.changed_files
    assert evidence.test_paths == inventories.test_paths
    assert {:ok, projection} = Core.feedback_projection(evidence)
    json = Jason.encode!(projection)
    assert byte_size(json) <= 1_048_576

    result = Map.put(evidence, :feedback_json, json)
    assert {:ok, report} = verify("contract_change", result)
    assert report["status"] == "passed", inspect(report)
    assert String.match?(report["evidence_ref"], ~r/\Asha256:[0-9a-f]{64}\z/)
  end

  test "adapter-maximal inventories bind evidence_ref under the 256,000-byte canonical ceiling" do
    contract_files = Enum.map(1..2_000, &max_contract_changed_path/1)
    contract_tests = Enum.map(1..2_000, &max_contract_test_path/1)
    assert byte_size(hd(contract_files)) == 1_024
    assert byte_size(List.last(contract_files)) == 1_024
    assert byte_size(hd(contract_tests)) == 1_024
    assert length(contract_files) == 2_000
    assert length(contract_tests) == 2_000

    contract = %{
      contract_result()
      | changed_files: contract_files,
        test_paths: contract_tests
    }

    cross_files = Enum.map(1..2_000, &max_contract_changed_path/1)
    cross_apps = Enum.map(1..256, &max_cross_app_id/1)
    cross_tests = Enum.map(1..256, &max_contract_test_path/1)
    assert byte_size(hd(cross_apps)) == 64
    assert byte_size(hd(cross_tests)) == 1_024

    cross = %{
      cross_result()
      | changed_files: cross_files,
        changed_apps: cross_apps,
        affected_apps: cross_apps,
        test_paths: cross_tests
    }

    security_paths = Enum.map(1..256, &max_security_test_path/1)
    assert byte_size(hd(security_paths)) == 1_024

    security =
      put_security_tests(security_result("security_regression_validated"), security_paths)

    for {profile, result} <- [
          {"contract_change", contract},
          {"cross_app", cross},
          {"security_regression", security}
        ] do
      assert {:ok, report} = verify(profile, result)
      assert report["status"] == "passed", inspect(report)
      assert String.match?(report["evidence_ref"], ~r/\Asha256:[0-9a-f]{64}\z/)

      assert {:ok, string_report} = verify(profile, stringify_json(result))
      assert string_report == report
    end
  end

  test "one-entry inventory change changes evidence_ref" do
    contract_files = Enum.map(1..2_000, &max_contract_changed_path/1)
    contract_tests = Enum.map(1..2_000, &max_contract_test_path/1)

    contract = %{
      contract_result()
      | changed_files: contract_files,
        test_paths: contract_tests
    }

    flipped_contract_files =
      List.replace_at(contract_files, -1, flip_padded_byte(List.last(contract_files)))

    flipped_contract = %{contract | changed_files: flipped_contract_files}

    assert_evidence_changes("contract_change", contract, [flipped_contract])

    cross_files = Enum.map(1..2_000, &max_contract_changed_path/1)
    cross_apps = Enum.map(1..256, &max_cross_app_id/1)
    cross_tests = Enum.map(1..256, &max_contract_test_path/1)

    cross = %{
      cross_result()
      | changed_files: cross_files,
        changed_apps: cross_apps,
        affected_apps: cross_apps,
        test_paths: cross_tests
    }

    flipped_cross_files =
      List.replace_at(cross_files, -1, flip_padded_byte(List.last(cross_files)))

    flipped_cross = %{cross | changed_files: flipped_cross_files}

    assert_evidence_changes("cross_app", cross, [flipped_cross])

    security_paths = Enum.map(1..256, &max_security_test_path/1)

    security =
      put_security_tests(security_result("security_regression_validated"), security_paths)

    flipped_security =
      security
      |> Map.update!(:attested_selected_tests, fn tests ->
        List.update_at(tests, -1, &Map.put(&1, :blob_sha256, @digest))
      end)
      |> Map.update!(:source_hashes, fn hashes ->
        List.update_at(hashes, -1, &Map.put(&1, :sha256, @digest))
      end)

    assert_evidence_changes("security_regression", security, [flipped_security])
  end

  test "contract_change rejects a valid handoff attached to the wrong stage" do
    swapped =
      contract_interrupted_capacity_result(:test)
      |> put_in([:test, "capacity_handoff"], contract_interrupted_handoff(:preflight))

    assert_invalid_evidence("contract_change", swapped)

    swapped_preflight =
      contract_interrupted_capacity_result(:preflight)
      |> put_in([:preflight, "capacity_handoff"], contract_interrupted_handoff(:test))

    assert_invalid_evidence("contract_change", swapped_preflight)

    three_batch =
      contract_capacity_result(:preflight)
      |> put_in([:preflight, "capacity_handoff"], three_batch_structural_handoff())

    assert_invalid_evidence("contract_change", three_batch)
  end

  test "capacity handoff is closed, bounded evidence and malformed handoffs fail closed" do
    result = cross_capacity_result()
    assert {:ok, report} = verify("cross_app", result)
    assert report["status"] == "blocked"

    interrupted = cross_capacity_result(capacity_handoff(:interrupted))
    assert {:ok, %{"status" => "blocked"}} = verify("cross_app", interrupted)

    tampered = put_in(result, [:test, "capacity_handoff", "available_budget_ms"], 1)
    assert_invalid_evidence("cross_app", tampered)

    interrupted_digest_tamper =
      put_in(
        interrupted,
        [:test, "capacity_handoff", "ordered_plan_sha256"],
        String.duplicate("0", 64)
      )

    assert_invalid_evidence("cross_app", interrupted_digest_tamper)

    extra = put_in(result, [:test, "capacity_handoff", "authority"], "forbidden")
    assert_invalid_evidence("cross_app", extra)

    for version <- [1, 2] do
      historical = cross_capacity_result(historical_capacity_handoff(version))
      assert_invalid_evidence("cross_app", historical)
    end

    default = default_capacity_result()
    assert {:ok, %{"status" => "blocked"}} = verify("default", default)

    # Exit-code / output-text heuristics must not invent capacity.
    assert_invalid_evidence(
      "default",
      default_result(exit_code: 137)
      |> Map.put(:reason, "validation_capacity_exceeded")
      |> Map.put(:termination, nil)
    )

    assert_invalid_evidence(
      "default",
      Map.put(default, :termination, Map.put(default.termination, "timed_out", "true"))
    )

    assert_invalid_evidence(
      "default",
      Map.put(default, :termination, %{
        "timed_out" => false,
        "killed" => false,
        "output_limit_exceeded" => false,
        "cancelled" => false
      })
    )
  end

  test "atom producer returns and recursively string-keyed Engine projections digest identically" do
    for {profile, result} <- [
          {"default", default_result()},
          {"cross_app", cross_result()},
          {"security_regression", security_result("security_regression_validated")},
          {"contract_change", contract_result()}
        ] do
      assert {:ok, atom_report} = verify(profile, result)
      assert {:ok, string_report} = verify(profile, stringify_json(result))
      assert atom_report == string_report
    end
  end

  test "reviewed-validation success wrapper peels closed control fields for all three adapters" do
    for {profile, result} <- [
          {"default", default_result()},
          {"cross_app", cross_result()},
          {"security_regression", security_result("security_regression_validated")},
          {"contract_change", contract_result()}
        ] do
      raw = stringify_json(result)
      assert {:ok, raw_report} = verify(profile, raw)

      # Success wrapper: interaction_outcome="" and note exactly "" (ReviewedValidation).
      wrapped =
        raw
        |> Map.merge(%{
          "interaction_outcome" => "",
          "request_id" => "irq_reviewed_wrapper",
          "note" => ""
        })

      assert {:ok, wrapped_report} = verify(profile, wrapped)
      assert wrapped_report == raw_report
      assert wrapped_report["status"] == "passed"

      # Unattended authorize uses empty request_id.
      unattended = Map.put(wrapped, "request_id", "")
      assert {:ok, unattended_report} = verify(profile, unattended)
      assert unattended_report == raw_report

      # Transport-only serialized result (Engine `validation.result` JSON string).
      assert {:ok, transport_report} = verify(profile, Jason.encode!(wrapped))
      assert transport_report == raw_report

      # Flat projection with transport duplicate + closed control fields.
      # Prefer flat fields: transport is dropped without re-decoding large output.
      flat_with_transport =
        Map.put(wrapped, "result", Jason.encode!(wrapped))

      assert {:ok, flat_report} = verify(profile, flat_with_transport)
      assert flat_report == raw_report
    end
  end

  test "malformed reviewed-validation wrapper metadata fails closed" do
    raw = stringify_json(default_result())

    partial =
      Map.merge(raw, %{
        "interaction_outcome" => "",
        "request_id" => "irq_partial"
      })

    assert_invalid_evidence("default", partial)

    bad_outcome =
      Map.merge(raw, %{
        "interaction_outcome" => "maybe",
        "request_id" => "irq_bad",
        "note" => ""
      })

    assert_invalid_evidence("default", bad_outcome)

    # Success wrapper requires note exactly ""; non-empty notes are not peeled.
    non_empty_note =
      Map.merge(raw, %{
        "interaction_outcome" => "",
        "request_id" => "irq_note",
        "note" => "approved after review"
      })

    assert_invalid_evidence("default", non_empty_note)

    # request_id must be "" or pass ApprovalAnswer.validate_request_id/1.
    bad_request_id =
      Map.merge(raw, %{
        "interaction_outcome" => "",
        "request_id" => "irq bad id",
        "note" => ""
      })

    assert_invalid_evidence("default", bad_request_id)

    # Adversarial: full validator envelope fused with denied/rework is forged.
    for outcome <- ~w(denied rework) do
      forged =
        Map.merge(raw, %{
          "interaction_outcome" => outcome,
          "request_id" => "irq_forged_#{outcome}",
          "note" => "operator note"
        })

      assert_invalid_evidence("default", forged)
    end

    non_map_transport = Map.put(raw, "result", 12)
    assert_invalid_evidence("default", non_map_transport)

    assert_invalid_evidence("default", "not-json")
    assert_invalid_evidence("default", Jason.encode!(["list"]))
    assert_invalid_evidence("default", %{"result" => "not-json"})

    # Nested/recursive transport wrappers decode at most one layer and fail closed.
    nested_transport = %{
      "result" => Jason.encode!(%{"result" => Jason.encode!(raw)})
    }

    assert_invalid_evidence("default", nested_transport)
    assert_invalid_evidence("default", Jason.encode!(%{"result" => Jason.encode!(raw)}))

    # Oversized sole transport is rejected before Jason.decode.
    oversized = String.duplicate("x", 16_777_216 * 2 + 2_097_152 + 1)
    assert_invalid_evidence("default", oversized)
    assert_invalid_evidence("default", %{"result" => oversized})

    control_only = %{
      "interaction_outcome" => "denied",
      "request_id" => "irq_denied",
      "note" => "no"
    }

    assert_invalid_evidence("default", control_only)

    # Unknown extras after peeling closed control fields remain fail-closed.
    wrapped_extra =
      raw
      |> Map.merge(%{
        "interaction_outcome" => "",
        "request_id" => "irq_extra",
        "note" => "",
        "extra" => true
      })

    assert_invalid_evidence("default", wrapped_extra)

    # Drifted candidate tree under a valid reviewed wrapper stays blocked.
    drifted =
      raw
      |> Map.put("validated_tree_oid", String.duplicate("f", 40))
      |> Map.merge(%{
        "interaction_outcome" => "",
        "request_id" => "irq_drift",
        "note" => ""
      })

    assert {:ok, report} = verify("default", drifted)
    assert report["status"] == "blocked"
    assert "candidate_state_drifted" in Enum.map(report["diagnostics"], & &1["code"])
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
    contract = contract_result()

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
      {"contract_change",
       Map.put(contract, :test_paths, Enum.map(1..2_001, &max_contract_test_path/1))},
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

  test "forged cross_app evidence cannot satisfy the contract_change adapter" do
    assert {:ok, report} = verify("contract_change", cross_result())
    assert report["status"] == "blocked"
    assert "validation_evidence_invalid" in Enum.map(report["diagnostics"], & &1["code"])
  end

  test "completed G2 CrossApp progress with sealed receipt produces a passed report" do
    {envelope, _receipt} = completed_progress_envelope()
    assert {:ok, report} = verify("cross_app", envelope)
    assert report["status"] == "passed"
    assert Enum.map(report["diagnostics"], & &1["gate_id"]) == @gate_ids["cross_app"]
    assert Enum.all?(report["diagnostics"], &(&1["decision"] == "passed"))
    assert String.match?(report["evidence_ref"], ~r/\Asha256:[0-9a-f]{64}\z/)

    refute inspect(report) =~ "passed_receipts"
    refute inspect(report) =~ "sealed_static_receipt"
  end

  test "completed empty-plan CrossApp progress produces a passed report" do
    {envelope, _receipt} = completed_progress_envelope(plan: [])
    assert envelope["progress"]["passed_receipts"] == []
    assert {:ok, report} = verify("cross_app", envelope)
    assert report["status"] == "passed"
    assert Enum.all?(report["diagnostics"], &(&1["decision"] == "passed"))
  end

  test "in-progress, capacity, missing receipt, and tampered G2 envelopes are invalid evidence" do
    {completed, receipt} = completed_progress_envelope()

    in_progress = %{
      "schema_version" => 1,
      "disposition_type" => "capacity_handoff",
      "progress_status" => "in_progress",
      "progress" => Map.put(completed["progress"], "status", "in_progress"),
      "progress_binding" => completed["progress_binding"],
      "passed" => true,
      "sealed_static_receipt" => receipt
    }

    assert_invalid_evidence("cross_app", in_progress)
    assert_invalid_evidence("cross_app", Map.delete(completed, "sealed_static_receipt"))

    forged_flags =
      completed
      |> Map.put("progress", Map.put(completed["progress"], "status", "in_progress"))

    assert_invalid_evidence("cross_app", forged_flags)

    tampered_prefix =
      put_in(completed, ["progress", "passed_receipts_digest"], String.duplicate("0", 64))

    assert_invalid_evidence("cross_app", tampered_prefix)

    extra = Map.put(completed, "extra", "nope")
    assert_invalid_evidence("cross_app", extra)
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
      reason: nil,
      stdout: "compile output",
      stderr: "",
      feedback: raw_feedback(passed, exit_code),
      feedback_json: "ignored feedback json",
      validated_tree_oid: @sha1,
      validated_head: @candidate_commit,
      termination: nil
    }
  end

  defp default_capacity_result do
    default_result(exit_code: 137)
    |> Map.merge(%{
      passed: false,
      reason: "validation_capacity_exceeded",
      feedback: raw_feedback(false, 137),
      termination: %{
        "timed_out" => false,
        "killed" => true,
        "output_limit_exceeded" => false,
        "cancelled" => false
      }
    })
  end

  defp default_containment_result do
    default_result(exit_code: 0)
    |> Map.merge(%{
      passed: false,
      reason: "validation_containment_failure",
      feedback: raw_feedback(false, 0),
      termination: %{
        "timed_out" => false,
        "killed" => true,
        "output_limit_exceeded" => false,
        "cancelled" => false,
        "containment_failure" => true
      }
    })
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

  defp completed_progress_envelope(opts \\ []) do
    plan = Keyword.get(opts, :plan, progress_plan())
    {:ok, plan_digest} = ValidationCapacityHandoff.ordered_plan_digest(plan)

    identities = %{
      "task_id" => "task_progress_g3a",
      "work_packet_digest" => "sha256:" <> @digest,
      "base_commit" => @base_oid,
      "base_tree_oid" => @base_oid,
      "candidate_head" => @base_oid,
      "candidate_tree_oid" => @sha1,
      "validation_plan_digest" => plan_digest,
      "toolchain_digest" => String.duplicate("3", 64),
      "dependency_baseline_digest" => String.duplicate("4", 64),
      "wrapper_digest" => String.duplicate("5", 64),
      "validator_id" => "coding_cross_app_validate",
      "principal_id" => "agent_principal",
      "configuration_digest" => String.duplicate("6", 64)
    }

    check = %{
      "status" => "completed",
      "passed" => true,
      "exit_code" => 0,
      "reason" => nil,
      "stdout_excerpt" => "",
      "stderr_excerpt" => "",
      "stdout_truncated" => false,
      "stderr_truncated" => false,
      "stdout_sha256" => @digest,
      "stderr_sha256" => @other_digest
    }

    {:ok, receipt, digest} =
      Actions.coding_cross_app_static_receipt_new(identities, %{
        "compile" => check,
        "xref" => check,
        "test_compile" => check
      })

    bindings = %{
      "identities" => identities,
      "planned_batches" => plan,
      "static_stage_receipt_digest" => digest
    }

    {:ok, fresh} = Actions.coding_cross_app_progress_new(bindings)

    {:ok, progress} =
      if plan == [] do
        {:ok, fresh}
      else
        receipts = Enum.map(plan, &Map.put(&1, "outcome", "passed"))

        Actions.coding_cross_app_progress_advance(fresh, bindings, %{
          "schema_version" => 1,
          "new_receipts" => receipts,
          "disposition" => %{"type" => "completed"}
        })
      end

    binding = %{
      "work_packet_digest" => identities["work_packet_digest"],
      "toolchain_digest" => identities["toolchain_digest"],
      "wrapper_digest" => identities["wrapper_digest"],
      "dependency_baseline_digest" => identities["dependency_baseline_digest"],
      "static_stage_receipt_digest" => digest
    }

    envelope = %{
      "schema_version" => 1,
      "disposition_type" => "completed",
      "progress_status" => "completed",
      "progress" => progress,
      "progress_binding" => binding,
      "passed" => true,
      "sealed_static_receipt" => receipt,
      "validated_tree_oid" => identities["candidate_tree_oid"],
      "validated_head" => identities["candidate_head"]
    }

    {envelope, receipt}
  end

  defp progress_plan do
    inv1 = String.duplicate("a", 64)
    inv2 = String.duplicate("b", 64)

    [
      %{
        "index" => 1,
        "total" => 2,
        "count" => 1,
        "label" => "batch-1-of-2-n1-#{inv1}",
        "inventory_sha256" => inv1
      },
      %{
        "index" => 2,
        "total" => 2,
        "count" => 1,
        "label" => "batch-2-of-2-n1-#{inv2}",
        "inventory_sha256" => inv2
      }
    ]
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

  defp cross_capacity_result(handoff \\ capacity_handoff()) do
    cross_result()
    |> Map.merge(%{
      passed: false,
      reason: "validation_capacity_exceeded",
      test:
        cross_check(passed: false, exit_code: nil, reason: "validation_capacity_exceeded")
        |> Map.put("capacity_handoff", handoff)
    })
  end

  defp contract_result do
    %{
      passed: true,
      reason: "contract_change_validated",
      base_commit: @base_oid,
      changed_files: ["apps/arbor_kernel/lib/arbor/contracts/coding/plan.ex"],
      test_paths: ["apps/arbor_kernel/test/arbor/contracts/admission_test.exs"],
      preflight: cross_check(),
      test: cross_check(),
      validated_tree_oid: @sha1,
      validated_head: @candidate_commit,
      feedback_json: "ignored feedback json"
    }
  end

  defp contract_failure(:preflight) do
    contract_result()
    |> Map.merge(%{
      passed: false,
      reason: "preflight_failed",
      preflight: cross_check(passed: false, exit_code: 1, reason: "preflight_failed"),
      test: skipped_check("preflight_failed")
    })
  end

  defp contract_failure(:test) do
    contract_result()
    |> Map.merge(%{
      passed: false,
      reason: "tests_failed",
      test: cross_check(passed: false, exit_code: 1, reason: "tests_failed")
    })
  end

  defp contract_surface_missing_result do
    contract_result()
    |> Map.merge(%{
      passed: false,
      reason: "contract_surface_missing",
      changed_files: ["apps/arbor_dashboard/lib/arbor/dashboard.ex"],
      test_paths: [],
      preflight: skipped_check("contract_surface_missing"),
      test: skipped_check("contract_surface_missing")
    })
  end

  defp contract_timeout_result do
    contract_result()
    |> Map.merge(%{
      passed: false,
      reason: "tests_timed_out",
      test: cross_check(passed: false, exit_code: nil, reason: "tests_timed_out")
    })
  end

  defp contract_preflight_timeout_result do
    contract_result()
    |> Map.merge(%{
      passed: false,
      reason: "preflight_timed_out",
      preflight: cross_check(passed: false, exit_code: nil, reason: "preflight_timed_out"),
      test: skipped_check("preflight_timed_out")
    })
  end

  defp contract_capacity_result(:preflight) do
    check = contract_capacity_check(:preflight)

    contract_result()
    |> Map.merge(%{
      passed: false,
      reason: "validation_capacity_exceeded",
      preflight: Map.put(check, "capacity_handoff", contract_capacity_handoff(:preflight)),
      test: skipped_check("validation_capacity_exceeded")
    })
  end

  defp contract_capacity_result(:test) do
    check = contract_capacity_check(:test)

    contract_result()
    |> Map.merge(%{
      passed: false,
      reason: "validation_capacity_exceeded",
      test: Map.put(check, "capacity_handoff", contract_capacity_handoff(:test))
    })
  end

  defp contract_capacity_check(:preflight) do
    cross_check(passed: false, exit_code: nil, reason: "validation_capacity_exceeded")
  end

  defp contract_capacity_check(:test) do
    cross_check(passed: false, exit_code: nil, reason: "validation_capacity_exceeded")
  end

  defp contract_containment_result(:preflight) do
    check =
      cross_check(passed: false, exit_code: 0, reason: "validation_containment_failure")
      |> Map.put("termination", containment_termination())

    contract_result()
    |> Map.merge(%{
      passed: false,
      reason: "validation_containment_failure",
      preflight: check,
      test: skipped_check("validation_containment_failure")
    })
  end

  defp contract_interrupted_capacity_result(:preflight) do
    check =
      cross_check(passed: false, exit_code: 0, reason: "validation_capacity_exceeded")
      |> Map.put("capacity_handoff", contract_interrupted_handoff(:preflight))

    contract_result()
    |> Map.merge(%{
      passed: false,
      reason: "validation_capacity_exceeded",
      preflight: check,
      test: skipped_check("validation_capacity_exceeded")
    })
  end

  defp contract_interrupted_capacity_result(:test) do
    check =
      cross_check(passed: false, exit_code: 0, reason: "validation_capacity_exceeded")
      |> Map.put("capacity_handoff", contract_interrupted_handoff(:test))

    contract_result()
    |> Map.merge(%{
      passed: false,
      reason: "validation_capacity_exceeded",
      test: check
    })
  end

  defp contract_interrupted_handoff(stage) do
    core = Arbor.Actions.Coding.ContractChange.Core
    preflight = core.preflight_batch(core.inventory_sha256(core.preflight_argv()))

    tests =
      core.tests_batch(
        1,
        core.inventory_sha256(["apps/arbor_kernel/test/arbor/contracts/admission_test.exs"])
      )

    plan =
      case stage do
        :preflight -> %{completed: [], interrupted: preflight, unstarted: [tests]}
        :test -> %{completed: [preflight], interrupted: tests, unstarted: []}
      end

    {:ok, check} = core.capacity_check(:runtime, 10_000, plan)
    Map.fetch!(check, "capacity_handoff")
  end

  defp containment_termination do
    %{
      "timed_out" => false,
      "killed" => true,
      "output_limit_exceeded" => false,
      "cancelled" => false,
      "containment_failure" => true
    }
  end

  defp contract_capacity_handoff(stage) do
    core = Arbor.Actions.Coding.ContractChange.Core
    preflight = core.preflight_batch(core.inventory_sha256(core.preflight_argv()))

    tests =
      core.tests_batch(
        1,
        core.inventory_sha256(["apps/arbor_kernel/test/arbor/contracts/admission_test.exs"])
      )

    plan =
      case stage do
        :preflight -> %{completed: [], unstarted: [preflight, tests]}
        :test -> %{completed: [preflight], unstarted: [tests]}
      end

    phase = if stage == :preflight, do: :structural, else: :runtime
    {:ok, check} = core.capacity_check(phase, 10_000, plan)
    Map.fetch!(check, "capacity_handoff")
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

  defp three_batch_structural_handoff do
    inventory = @digest

    batches =
      Enum.map(1..3, fn index ->
        %{
          "index" => index,
          "total" => 3,
          "count" => 1,
          "label" => "batch-#{index}-of-3-n1-#{inventory}",
          "inventory_sha256" => inventory
        }
      end)

    {:ok, plan_digest} = ValidationCapacityHandoff.ordered_plan_digest(batches)

    {:ok, handoff} =
      ValidationCapacityHandoff.normalize(%{
        "schema_version" => ValidationCapacityHandoff.schema_version(),
        "phase" => "structural",
        "available_budget_ms" => 0,
        "per_batch_budget_ms" => 1_000,
        "completed_batch_count" => 0,
        "completed_file_count" => 0,
        "unstarted_batch_count" => 3,
        "unstarted_file_count" => 3,
        "total_batch_count" => 3,
        "total_file_count" => 3,
        "ordered_plan_sha256" => plan_digest,
        "interrupted_batch" => nil,
        "unstarted_batches" => batches
      })

    handoff
  end

  defp capacity_handoff, do: capacity_handoff(:structural)

  defp capacity_handoff(:structural) do
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
        "completed_batch_count" => 0,
        "completed_file_count" => 0,
        "unstarted_batch_count" => 1,
        "unstarted_file_count" => 1,
        "total_batch_count" => 1,
        "total_file_count" => 1,
        "ordered_plan_sha256" => plan_digest,
        "interrupted_batch" => nil,
        "unstarted_batches" => [batch]
      })

    handoff
  end

  defp capacity_handoff(:interrupted) do
    inventory = @digest

    batch = %{
      "index" => 1,
      "total" => 1,
      "count" => 1,
      "label" => "batch-1-of-1-n1-#{inventory}",
      "inventory_sha256" => inventory
    }

    {:ok, plan_digest} = ValidationCapacityHandoff.ordered_plan_digest([batch])

    {:ok, handoff} =
      ValidationCapacityHandoff.normalize(%{
        "schema_version" => ValidationCapacityHandoff.schema_version(),
        "phase" => "runtime",
        "available_budget_ms" => 0,
        "per_batch_budget_ms" => 1_000,
        "completed_batch_count" => 0,
        "completed_file_count" => 0,
        "unstarted_batch_count" => 0,
        "unstarted_file_count" => 0,
        "total_batch_count" => 1,
        "total_file_count" => 1,
        "ordered_plan_sha256" => plan_digest,
        "interrupted_batch" => batch,
        "unstarted_batches" => []
      })

    handoff
  end

  defp historical_capacity_handoff(version) when version in [1, 2] do
    handoff =
      capacity_handoff()
      |> Map.delete("interrupted_batch")
      |> Map.put("schema_version", version)

    if version == 1 do
      Map.put(handoff, "required_budget_ms", handoff["per_batch_budget_ms"])
    else
      handoff
    end
  end

  defp security_result(reason) do
    {candidate, base} = security_legs(reason)
    passed = reason == "security_regression_validated"
    path = "test/security_regression_test.exs"

    termination =
      if reason == "validation_capacity_exceeded" do
        %{
          "timed_out" => true,
          "killed" => false,
          "output_limit_exceeded" => false,
          "cancelled" => false
        }
      else
        nil
      end

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
      feedback_json: "ignored feedback json",
      termination: termination
    }
  end

  defp security_legs("security_regression_validated"),
    do: {candidate_pass_leg(), base_fail_leg()}

  defp security_legs("candidate_source_changed"),
    do: {%{candidate_pass_leg() | status: "source_changed", completed: false}, not_run_leg()}

  defp security_legs("validation_capacity_exceeded") do
    candidate = %{
      candidate_pass_leg()
      | timed_out: true,
        exit_code: 1,
        passed: 0,
        test_failures: 1
    }

    {candidate, not_run_leg()}
  end

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
        "output_sha256" => @digest,
        "untrusted_diagnostic_output" => ""
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

  defp max_contract_changed_path(i) do
    index = String.pad_leading(Integer.to_string(i), 4, "0")
    prefix = "apps/arbor_kernel/lib/arbor/contracts/"
    suffix = "_#{index}.ex"
    prefix <> String.duplicate("a", 1_024 - byte_size(prefix) - byte_size(suffix)) <> suffix
  end

  defp max_contract_test_path(i) do
    index = String.pad_leading(Integer.to_string(i), 4, "0")
    prefix = "apps/arbor_kernel/test/arbor/contracts/"
    suffix = "_#{index}_test.exs"
    prefix <> String.duplicate("a", 1_024 - byte_size(prefix) - byte_size(suffix)) <> suffix
  end

  defp max_cross_app_id(i) do
    index = String.pad_leading(Integer.to_string(i), 3, "0")
    suffix = "_#{index}"
    String.duplicate("a", 64 - byte_size(suffix)) <> suffix
  end

  defp max_security_test_path(i) do
    index = String.pad_leading(Integer.to_string(i), 3, "0")
    prefix = "test/"
    suffix = "_#{index}_test.exs"
    prefix <> String.duplicate("a", 1_024 - byte_size(prefix) - byte_size(suffix)) <> suffix
  end

  defp flip_padded_byte(path) when is_binary(path) do
    case :binary.match(path, "aa") do
      {start, _} ->
        <<prefix::binary-size(start), _byte, rest::binary>> = path
        flipped = prefix <> "b" <> rest
        assert flipped != path
        assert byte_size(flipped) == byte_size(path)
        flipped

      :nomatch ->
        flunk("expected a padded ASCII region in #{inspect(path)}")
    end
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
