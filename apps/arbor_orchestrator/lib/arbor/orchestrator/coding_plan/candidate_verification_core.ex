defmodule Arbor.Orchestrator.CodingPlan.CandidateVerificationCore do
  @moduledoc false

  alias Arbor.Contracts.Coding.{Diagnostic, ValidationCapacityHandoff, VerificationReport}
  alias Arbor.Orchestrator.CodingPlan.ValidationProgram

  @max_raw_output_bytes 16_777_216
  @max_feedback_json_bytes 1_048_576
  @max_path_bytes 1_024
  @max_path_list 2_000
  @max_security_tests 256
  @max_count 10_000_000
  @max_evidence_bytes 256_000

  @default_fields ~w[
    path exit_code passed stdout stderr feedback feedback_json validated_tree_oid validated_head
  ]a
  @compile_feedback_fields ~w[
    exit_code passed stdout_excerpt stderr_excerpt stdout_truncated stderr_truncated
    stdout_sha256 stderr_sha256
  ]
  @cross_fields ~w[
    passed reason base_commit changed_files changed_apps affected_apps test_paths root_wide
    compile xref test_compile test validated_tree_oid validated_head feedback_json
  ]a
  @cross_check_fields ~w[
    status passed exit_code reason stdout_excerpt stderr_excerpt stdout_truncated stderr_truncated
    stdout_sha256 stderr_sha256
  ]
  @security_fields ~w[
    passed reason base_commit candidate_fingerprint test_paths source_hashes candidate base diagnostics
    evidence_type attested_base_commit attested_candidate_commit attested_candidate_tree_oid
    attested_diff_sha256 attested_selected_tests review_attestation_digest council_decision_digest
    feedback_json
  ]a
  @security_leg_fields ~w[
    completed status exit_code timed_out executed passed test_failures setup_failures skipped excluded
    invalid
  ]a
  @security_diagnostic_fields ~w[exit_code timed_out output_bytes output_sha256]

  @gates %{
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

  @candidate_statuses ~w[
    completed source_changed artifact_invalid helper_missing execution_failed suite_incomplete
  ]
  @base_statuses ~w[
    completed artifact_invalid helper_missing snapshot_failed overlay_failed execution_failed not_run
    suite_incomplete
  ]

  @security_reasons ~w[
    security_regression_validated
    candidate_source_changed candidate_timeout candidate_artifact_invalid candidate_helper_missing
    candidate_execution_failed candidate_suite_incomplete candidate_setup_failed candidate_zero_tests
    candidate_tests_failed candidate_exit_nonzero
    base_timeout base_artifact_invalid base_helper_missing base_snapshot_failed base_overlay_failed
    base_execution_failed base_not_run base_suite_incomplete base_setup_failed base_zero_tests
    base_tests_passed base_non_test_failure base_exit_zero
  ]

  @security_domain_failures ~w[candidate_tests_failed base_tests_passed]
  @cross_domain_failures ~w[compile_failed xref_failed test_compile_failed tests_failed]

  @type verify_error ::
          :invalid_candidate_tree_oid | :invalid_observed_at | :invalid_validation_program

  @doc "Build a canonical verification report from one owner-observed candidate and action result."
  @spec verify(map(), String.t(), term(), String.t()) ::
          {:ok, map()} | {:error, verify_error()}
  def verify(program, candidate_tree_oid, action_result, observed_at) do
    with :ok <- ValidationProgram.validate(program),
         true <- valid_oid?(candidate_tree_oid),
         {:ok, observed_at} <- normalize_observed_at(observed_at) do
      do_verify(program, candidate_tree_oid, action_result, observed_at)
    else
      {:error, :invalid_validation_program} -> {:error, :invalid_validation_program}
      {:error, :invalid_observed_at} -> {:error, :invalid_observed_at}
      false -> {:error, :invalid_candidate_tree_oid}
      _other -> {:error, :invalid_validation_program}
    end
  rescue
    _error -> fail_closed_if_outer_inputs_valid(program, candidate_tree_oid, observed_at)
  catch
    _kind, _reason -> fail_closed_if_outer_inputs_valid(program, candidate_tree_oid, observed_at)
  end

  defp do_verify(program, candidate_tree_oid, action_result, observed_at) do
    profile = program["profile_id"]
    candidate_ref = "git-tree:" <> candidate_tree_oid

    case adapt(program["result_adapter"], action_result) do
      {:ok, evidence, assessment} ->
        case evidence_ref(evidence) do
          {:ok, evidence_ref} ->
            if evidence["candidate_tree_oid"] != candidate_tree_oid do
              uniform_report(
                profile,
                candidate_ref,
                observed_at,
                "blocked",
                "candidate_state_drifted",
                evidence_ref
              )
            else
              assessed_report(
                profile,
                candidate_ref,
                observed_at,
                assessment,
                evidence_ref
              )
            end

          _error ->
            invalid_evidence_report(profile, candidate_ref, observed_at)
        end

      :error ->
        invalid_evidence_report(profile, candidate_ref, observed_at)
    end
  end

  defp adapt("mix_compile_v1", result), do: adapt_default(result)
  defp adapt("cross_app_v1", result), do: adapt_cross_app(result)
  defp adapt("security_regression_v1", result), do: adapt_security(result)
  defp adapt(_adapter, _result), do: :error

  defp adapt_default(result) do
    with {:ok, values, _style} <- exact_envelope(result, @default_fields),
         true <- bounded_text?(values.path, 4_096),
         true <- valid_exit_code?(values.exit_code),
         true <- is_boolean(values.passed),
         true <- values.passed == (values.exit_code == 0),
         true <- bounded_binary?(values.stdout, @max_raw_output_bytes),
         true <- bounded_binary?(values.stderr, @max_raw_output_bytes),
         {:ok, feedback} <-
           normalize_compile_feedback(values.feedback, values.passed, values.exit_code),
         true <- bounded_binary?(values.feedback_json, @max_feedback_json_bytes),
         true <- valid_oid?(values.validated_tree_oid),
         true <- valid_oid?(values.validated_head) do
      evidence = %{
        "adapter" => "mix_compile_v1",
        "candidate_tree_oid" => values.validated_tree_oid,
        "validated_head" => values.validated_head,
        "passed" => values.passed,
        "exit_code" => values.exit_code,
        "feedback" => feedback
      }

      assessment = %{
        status: if(values.passed, do: "passed", else: "failed"),
        gates: [
          if(values.passed,
            do: {:passed, "validation_passed"},
            else: {:blocked, "compile_failed"}
          )
        ]
      }

      {:ok, evidence, assessment}
    else
      _other -> :error
    end
  end

  defp normalize_compile_feedback(feedback, passed, exit_code) do
    with {:ok, values} <- exact_string_object(feedback, @compile_feedback_fields),
         true <- values["passed"] == passed,
         true <- values["exit_code"] == exit_code,
         true <- bounded_binary?(values["stdout_excerpt"], 8_192),
         true <- bounded_binary?(values["stderr_excerpt"], 8_192),
         true <- is_boolean(values["stdout_truncated"]),
         true <- is_boolean(values["stderr_truncated"]),
         true <- valid_sha256?(values["stdout_sha256"]),
         true <- valid_sha256?(values["stderr_sha256"]) do
      {:ok,
       %{
         "stdout_truncated" => values["stdout_truncated"],
         "stderr_truncated" => values["stderr_truncated"],
         "stdout_sha256" => values["stdout_sha256"],
         "stderr_sha256" => values["stderr_sha256"]
       }}
    else
      _other -> :error
    end
  end

  defp adapt_cross_app(result) do
    with {:ok, values, _style} <- exact_envelope(result, @cross_fields),
         true <- is_boolean(values.passed),
         true <- is_binary(values.reason),
         true <- valid_oid?(values.base_commit),
         true <- bounded_string_list?(values.changed_files, @max_path_list, @max_path_bytes),
         true <- bounded_string_list?(values.changed_apps, 256, 64),
         true <- bounded_string_list?(values.affected_apps, 256, 64),
         true <- bounded_string_list?(values.test_paths, 256, @max_path_bytes),
         true <- ordered_unique?(values.changed_files),
         true <- ordered_unique?(values.changed_apps),
         true <- ordered_unique?(values.affected_apps),
         true <- ordered_unique?(values.test_paths),
         true <- is_boolean(values.root_wide),
         {:ok, compile} <- adapt_cross_check(:compile, values.compile),
         {:ok, xref} <- adapt_cross_check(:xref, values.xref),
         {:ok, test_compile} <- adapt_cross_check(:test_compile, values.test_compile),
         {:ok, test} <- adapt_cross_check(:test, values.test),
         true <- valid_cross_sequence?(compile, xref, test_compile, test),
         expected_reason <- cross_reason(compile, xref, test_compile, test),
         true <- values.reason == expected_reason,
         true <- values.passed == Enum.all?([compile, xref, test_compile, test], & &1["passed"]),
         true <- valid_oid?(values.validated_tree_oid),
         true <- valid_oid?(values.validated_head),
         true <- bounded_binary?(values.feedback_json, @max_feedback_json_bytes) do
      checks = [compile, xref, test_compile, test]

      evidence = %{
        "adapter" => "cross_app_v1",
        "candidate_tree_oid" => values.validated_tree_oid,
        "validated_head" => values.validated_head,
        "base_commit" => values.base_commit,
        "passed" => values.passed,
        "reason" => values.reason,
        "changed_files" => values.changed_files,
        "changed_apps" => values.changed_apps,
        "affected_apps" => values.affected_apps,
        "test_paths" => values.test_paths,
        "root_wide" => values.root_wide,
        "checks" => checks
      }

      status =
        cond do
          values.passed -> "passed"
          values.reason in @cross_domain_failures -> "failed"
          true -> "blocked"
        end

      gate_checks = Enum.zip([:compile, :xref, :test_compile, :test], checks)
      {:ok, evidence, %{status: status, gates: Enum.map(gate_checks, &cross_gate/1)}}
    else
      _other -> :error
    end
  end

  defp adapt_cross_check(stage, check) do
    with true <- is_map(check) and not is_struct(check),
         fields <-
           if(Map.has_key?(check, "capacity_handoff"),
             do: @cross_check_fields ++ ["capacity_handoff"],
             else: @cross_check_fields
           ),
         {:ok, values} <- exact_string_object(check, fields),
         true <- values["status"] in ["completed", "skipped"],
         true <- is_boolean(values["passed"]),
         true <- valid_optional_exit_code?(values["exit_code"]),
         true <- is_nil(values["reason"]) or bounded_text?(values["reason"], 64),
         true <- bounded_binary?(values["stdout_excerpt"], 8_192),
         true <- bounded_binary?(values["stderr_excerpt"], 8_192),
         true <- is_boolean(values["stdout_truncated"]),
         true <- is_boolean(values["stderr_truncated"]),
         true <- valid_sha256?(values["stdout_sha256"]),
         true <- valid_sha256?(values["stderr_sha256"]),
         {:ok, capacity} <- normalize_capacity(Map.get(values, "capacity_handoff")),
         true <- valid_cross_check_semantics?(stage, values, capacity) do
      projection = %{
        "status" => values["status"],
        "passed" => values["passed"],
        "exit_code" => values["exit_code"],
        "reason" => values["reason"],
        "stdout_truncated" => values["stdout_truncated"],
        "stderr_truncated" => values["stderr_truncated"],
        "stdout_sha256" => values["stdout_sha256"],
        "stderr_sha256" => values["stderr_sha256"]
      }

      projection =
        if capacity, do: Map.put(projection, "capacity_handoff", capacity), else: projection

      {:ok, projection}
    else
      _other -> :error
    end
  end

  defp normalize_capacity(nil), do: {:ok, nil}

  defp normalize_capacity(capacity) when is_map(capacity) and not is_struct(capacity) do
    with {:ok, normalized} <- ValidationCapacityHandoff.normalize(capacity),
         true <- capacity == normalized do
      {:ok, normalized}
    else
      _other -> :error
    end
  end

  defp normalize_capacity(_capacity), do: :error

  defp valid_cross_check_semantics?(:compile, values, nil) do
    values["status"] == "completed" and is_nil(values["reason"]) and
      completed_exit_consistent?(values)
  end

  defp valid_cross_check_semantics?(:xref, values, nil) do
    case {values["status"], values["passed"], values["exit_code"], values["reason"]} do
      {"completed", true, 0, nil} -> true
      {"completed", false, code, "xref_failed"} when is_integer(code) and code != 0 -> true
      {"skipped", false, nil, "compile_failed"} -> true
      _other -> false
    end
  end

  defp valid_cross_check_semantics?(:test_compile, values, nil) do
    case {values["status"], values["passed"], values["exit_code"], values["reason"]} do
      {"completed", true, 0, nil} ->
        true

      {"completed", false, code, "test_compile_failed"} when is_integer(code) and code != 0 ->
        true

      {"skipped", false, nil, reason} when reason in ["compile_failed", "xref_failed"] ->
        true

      _other ->
        false
    end
  end

  defp valid_cross_check_semantics?(:test, values, capacity) do
    tuple = {values["status"], values["passed"], values["exit_code"], values["reason"]}

    case {tuple, capacity} do
      {{"completed", true, 0, nil}, nil} ->
        true

      {{"completed", false, code, "tests_failed"}, nil} when is_integer(code) and code != 0 ->
        true

      {{"completed", false, code, "tests_timed_out"}, nil}
      when is_nil(code) or is_integer(code) ->
        true

      {{"completed", false, nil, "validation_capacity_exceeded"}, handoff}
      when is_map(handoff) ->
        true

      {{"skipped", true, 0, reason}, nil}
      when reason in ["no_affected_app_tests", "no_existing_test_files"] ->
        true

      {{"skipped", false, nil, reason}, nil}
      when reason in ["compile_failed", "xref_failed", "test_compile_failed"] ->
        true

      _other ->
        false
    end
  end

  defp valid_cross_check_semantics?(_stage, _values, _capacity), do: false

  defp completed_exit_consistent?(%{"passed" => true, "exit_code" => 0}), do: true

  defp completed_exit_consistent?(%{"passed" => false, "exit_code" => code})
       when is_integer(code) and code != 0,
       do: true

  defp completed_exit_consistent?(_values), do: false

  defp valid_cross_sequence?(compile, xref, test_compile, test) do
    cond do
      not compile["passed"] ->
        skipped_for?(xref, "compile_failed") and skipped_for?(test_compile, "compile_failed") and
          skipped_for?(test, "compile_failed")

      not xref["passed"] ->
        skipped_for?(test_compile, "xref_failed") and skipped_for?(test, "xref_failed")

      not test_compile["passed"] ->
        skipped_for?(test, "test_compile_failed")

      true ->
        true
    end
  end

  defp skipped_for?(check, reason) do
    check["status"] == "skipped" and check["passed"] == false and check["reason"] == reason
  end

  defp cross_reason(compile, xref, test_compile, test) do
    cond do
      not compile["passed"] -> compile["reason"] || "compile_failed"
      not xref["passed"] -> xref["reason"] || "xref_failed"
      not test_compile["passed"] -> test_compile["reason"] || "test_compile_failed"
      not test["passed"] -> test["reason"] || "tests_failed"
      true -> "cross_app_validated"
    end
  end

  defp cross_gate({_stage, %{"passed" => true}}), do: {:passed, "validation_passed"}

  defp cross_gate({_stage, %{"reason" => reason}}) when is_binary(reason),
    do: {:blocked, reason}

  defp cross_gate({stage, _check}), do: {:blocked, cross_stage_failure_code(stage)}

  defp cross_stage_failure_code(:compile), do: "compile_failed"
  defp cross_stage_failure_code(:xref), do: "xref_failed"
  defp cross_stage_failure_code(:test_compile), do: "test_compile_failed"
  defp cross_stage_failure_code(:test), do: "tests_failed"

  defp adapt_security(result) do
    with {:ok, values, style} <- exact_envelope(result, @security_fields),
         true <- is_boolean(values.passed),
         true <- values.reason in @security_reasons,
         true <- valid_oid?(values.base_commit),
         true <- valid_sha256?(values.candidate_fingerprint),
         {:ok, test_paths} <-
           normalize_string_list(values.test_paths, @max_security_tests, @max_path_bytes),
         {:ok, source_hashes} <- normalize_security_sources(values.source_hashes, style),
         {:ok, candidate} <- normalize_security_leg(values.candidate, style, :candidate),
         {:ok, base} <- normalize_security_leg(values.base, style, :base),
         {:ok, diagnostics} <-
           normalize_security_diagnostics(values.diagnostics, style, candidate, base),
         true <- values.evidence_type == "reviewed_regression_evidence",
         true <- valid_oid?(values.attested_base_commit),
         true <- values.attested_base_commit == values.base_commit,
         true <- valid_oid?(values.attested_candidate_commit),
         true <- valid_oid?(values.attested_candidate_tree_oid),
         true <- valid_sha256?(values.attested_diff_sha256),
         {:ok, selected_tests} <- normalize_selected_tests(values.attested_selected_tests, style),
         true <- selected_tests_bound?(test_paths, source_hashes, selected_tests),
         true <- valid_sha256?(values.review_attestation_digest),
         true <- valid_sha256?(values.council_decision_digest),
         true <- bounded_binary?(values.feedback_json, @max_feedback_json_bytes),
         true <- valid_security_verdict?(values.passed, values.reason, candidate, base) do
      evidence = %{
        "adapter" => "security_regression_v1",
        "candidate_tree_oid" => values.attested_candidate_tree_oid,
        "passed" => values.passed,
        "reason" => values.reason,
        "candidate_fingerprint" => values.candidate_fingerprint,
        "attested_base_commit" => values.attested_base_commit,
        "attested_candidate_commit" => values.attested_candidate_commit,
        "attested_diff_sha256" => values.attested_diff_sha256,
        "review_attestation_digest" => values.review_attestation_digest,
        "council_decision_digest" => values.council_decision_digest,
        "selected_tests" => selected_tests,
        "candidate" => candidate,
        "base" => base,
        "diagnostics" => diagnostics
      }

      status =
        cond do
          values.passed -> "passed"
          values.reason in @security_domain_failures -> "failed"
          true -> "blocked"
        end

      {:ok, evidence,
       %{status: status, gates: security_gates(values.reason, values.passed, base)}}
    else
      _other -> :error
    end
  end

  defp normalize_security_sources(sources, style) do
    with {:ok, sources} <- bounded_list(sources, @max_security_tests, & &1),
         {:ok, normalized} <-
           map_list(sources, fn source ->
             with {:ok, values} <- exact_styled_object(source, [:path, :sha256], style),
                  true <- bounded_text?(values.path, @max_path_bytes),
                  true <- valid_sha256?(values.sha256) do
               {:ok, %{"path" => values.path, "sha256" => values.sha256}}
             else
               _other -> :error
             end
           end) do
      {:ok, normalized}
    else
      _other -> :error
    end
  end

  defp normalize_selected_tests(tests, style) do
    with {:ok, tests} <- bounded_list(tests, @max_security_tests, & &1),
         {:ok, normalized} <-
           map_list(tests, fn test ->
             with {:ok, values} <- exact_styled_object(test, [:path, :blob_sha256], style),
                  true <- bounded_text?(values.path, @max_path_bytes),
                  true <- valid_sha256?(values.blob_sha256) do
               {:ok, %{"path" => values.path, "blob_sha256" => values.blob_sha256}}
             else
               _other -> :error
             end
           end) do
      {:ok, normalized}
    else
      _other -> :error
    end
  end

  defp selected_tests_bound?(test_paths, source_hashes, selected_tests) do
    source_paths = Enum.map(source_hashes, & &1["path"])
    selected_paths = Enum.map(selected_tests, & &1["path"])

    ordered_unique?(test_paths) and ordered_unique?(source_paths) and
      ordered_unique?(selected_paths) and test_paths == source_paths and
      source_paths == selected_paths and
      Enum.zip(source_hashes, selected_tests)
      |> Enum.all?(fn {source, selected} ->
        source["sha256"] == selected["blob_sha256"]
      end)
  end

  defp normalize_security_leg(leg, style, kind) do
    with {:ok, values} <- exact_styled_object(leg, @security_leg_fields, style),
         statuses <- if(kind == :candidate, do: @candidate_statuses, else: @base_statuses),
         true <- values.status in statuses,
         true <- is_boolean(values.completed),
         true <- values.completed == (values.status == "completed"),
         true <- valid_optional_exit_code?(values.exit_code),
         true <- is_boolean(values.timed_out),
         true <- valid_counts?(values) do
      {:ok,
       %{
         "completed" => values.completed,
         "status" => values.status,
         "exit_code" => values.exit_code,
         "timed_out" => values.timed_out,
         "executed" => values.executed,
         "passed" => values.passed,
         "test_failures" => values.test_failures,
         "setup_failures" => values.setup_failures,
         "skipped" => values.skipped,
         "excluded" => values.excluded,
         "invalid" => values.invalid
       }}
    else
      _other -> :error
    end
  end

  defp valid_counts?(values) do
    counts = [
      values.executed,
      values.passed,
      values.test_failures,
      values.setup_failures,
      values.skipped,
      values.excluded,
      values.invalid
    ]

    Enum.all?(counts, &(is_integer(&1) and &1 >= 0 and &1 <= @max_count)) and
      values.executed == values.passed + values.test_failures
  end

  defp normalize_security_diagnostics(diagnostics, style, candidate, base) do
    case exact_styled_object(diagnostics, [:candidate, :base], style) do
      {:ok, values} ->
        with {:ok, candidate_diagnostic} <- normalize_security_diagnostic(values.candidate),
             {:ok, base_diagnostic} <- normalize_security_diagnostic(values.base),
             true <- diagnostic_consistent?(candidate_diagnostic, candidate, :candidate),
             true <- diagnostic_consistent?(base_diagnostic, base, :base) do
          {:ok, %{"candidate" => candidate_diagnostic, "base" => base_diagnostic}}
        else
          _other -> :error
        end

      _other ->
        :error
    end
  end

  defp normalize_security_diagnostic(diagnostic)
       when is_map(diagnostic) and not is_struct(diagnostic) and map_size(diagnostic) == 0,
       do: {:ok, %{}}

  defp normalize_security_diagnostic(diagnostic) do
    with {:ok, values} <- exact_string_object(diagnostic, @security_diagnostic_fields),
         true <- valid_optional_exit_code?(values["exit_code"]),
         true <- is_boolean(values["timed_out"]),
         true <-
           is_integer(values["output_bytes"]) and values["output_bytes"] >= 0 and
             values["output_bytes"] <= @max_raw_output_bytes,
         true <- valid_sha256?(values["output_sha256"]) do
      {:ok,
       %{
         "exit_code" => values["exit_code"],
         "timed_out" => values["timed_out"],
         "output_bytes" => values["output_bytes"],
         "output_sha256" => values["output_sha256"]
       }}
    else
      _other -> :error
    end
  end

  defp diagnostic_consistent?(diagnostic, leg, kind) when map_size(diagnostic) == 0 do
    case {kind, leg["status"]} do
      {:candidate, status} when status in ["source_changed", "helper_missing"] ->
        true

      {:base, status}
      when status in ["helper_missing", "snapshot_failed", "overlay_failed", "not_run"] ->
        true

      _other ->
        false
    end
  end

  defp diagnostic_consistent?(diagnostic, leg, _kind) do
    diagnostic["exit_code"] == leg["exit_code"] and
      diagnostic["timed_out"] == leg["timed_out"]
  end

  defp valid_security_verdict?(passed, reason, candidate, base) do
    expected = security_reason(candidate, base, reason)
    reason == expected and passed == (reason == "security_regression_validated")
  end

  defp security_reason(candidate, base, supplied_reason) do
    case candidate_reason(candidate) do
      :clean ->
        if supplied_reason == "candidate_suite_incomplete" and base["status"] == "not_run" do
          supplied_reason
        else
          security_base_reason(base, supplied_reason)
        end

      reason ->
        reason
    end
  end

  defp security_base_reason(base, supplied_reason) do
    case base_reason(base) do
      :validated ->
        if supplied_reason == "base_suite_incomplete",
          do: supplied_reason,
          else: "security_regression_validated"

      reason ->
        reason
    end
  end

  defp candidate_reason(candidate) do
    cond do
      candidate["status"] == "source_changed" -> "candidate_source_changed"
      candidate["timed_out"] -> "candidate_timeout"
      candidate["status"] != "completed" -> candidate_incomplete_reason(candidate["status"])
      candidate["setup_failures"] > 0 or candidate["invalid"] > 0 -> "candidate_setup_failed"
      candidate["executed"] < 1 -> "candidate_zero_tests"
      candidate["test_failures"] > 0 -> "candidate_tests_failed"
      candidate["exit_code"] != 0 -> "candidate_exit_nonzero"
      true -> :clean
    end
  end

  defp base_reason(base) do
    cond do
      base["timed_out"] -> "base_timeout"
      base["status"] != "completed" -> base_incomplete_reason(base["status"])
      base["setup_failures"] > 0 or base["invalid"] > 0 -> "base_setup_failed"
      base["executed"] < 1 -> "base_zero_tests"
      base["test_failures"] < 1 and base["exit_code"] == 0 -> "base_tests_passed"
      base["test_failures"] < 1 -> "base_non_test_failure"
      base["exit_code"] == 0 -> "base_exit_zero"
      true -> :validated
    end
  end

  defp candidate_incomplete_reason("artifact_invalid"), do: "candidate_artifact_invalid"
  defp candidate_incomplete_reason("helper_missing"), do: "candidate_helper_missing"
  defp candidate_incomplete_reason("execution_failed"), do: "candidate_execution_failed"
  defp candidate_incomplete_reason(_status), do: "candidate_suite_incomplete"

  defp base_incomplete_reason("artifact_invalid"), do: "base_artifact_invalid"
  defp base_incomplete_reason("helper_missing"), do: "base_helper_missing"
  defp base_incomplete_reason("snapshot_failed"), do: "base_snapshot_failed"
  defp base_incomplete_reason("overlay_failed"), do: "base_overlay_failed"
  defp base_incomplete_reason("execution_failed"), do: "base_execution_failed"
  defp base_incomplete_reason("not_run"), do: "base_not_run"
  defp base_incomplete_reason(_status), do: "base_suite_incomplete"

  defp security_gates(_reason, true, _base) do
    [
      {:passed, "attestation_bound"},
      {:passed, "validation_passed"},
      {:passed, "validation_passed"}
    ]
  end

  defp security_gates("candidate_" <> _ = reason, false, _base) do
    [
      {:passed, "attestation_bound"},
      {:blocked, reason},
      {:blocked, "base_not_run"}
    ]
  end

  defp security_gates(reason, false, _base) do
    [
      {:passed, "attestation_bound"},
      {:passed, "validation_passed"},
      {:blocked, reason}
    ]
  end

  defp assessed_report(profile, candidate_ref, observed_at, assessment, evidence_ref) do
    with {:ok, diagnostics} <-
           build_diagnostics(profile, assessment.gates, observed_at, evidence_ref),
         {:ok, report} <-
           VerificationReport.normalize(%{
             version: VerificationReport.schema_version(),
             status: assessment.status,
             profile: profile,
             candidate_ref: candidate_ref,
             observed_at: observed_at,
             diagnostics: diagnostics,
             evidence_ref: evidence_ref
           }) do
      {:ok, report}
    else
      _other -> {:error, :invalid_observed_at}
    end
  end

  defp uniform_report(profile, candidate_ref, observed_at, status, code, evidence_ref) do
    gates = Enum.map(@gates[profile], fn _gate -> {:blocked, code} end)

    assessed_report(
      profile,
      candidate_ref,
      observed_at,
      %{status: status, gates: gates},
      evidence_ref
    )
  end

  defp invalid_evidence_report(profile, candidate_ref, observed_at) do
    uniform_report(
      profile,
      candidate_ref,
      observed_at,
      "blocked",
      "validation_evidence_invalid",
      nil
    )
  end

  defp build_diagnostics(profile, gate_results, observed_at, evidence_ref) do
    gates = @gates[profile]

    if length(gates) == length(gate_results) do
      gates
      |> Enum.zip(gate_results)
      |> map_list(fn {gate_id, {decision, code}} ->
        Diagnostic.normalize(%{
          version: Diagnostic.schema_version(),
          gate_id: gate_id,
          phase: "validation",
          decision: Atom.to_string(decision),
          code: code,
          observed_at: observed_at,
          evidence_ref: evidence_ref
        })
      end)
    else
      :error
    end
  end

  defp evidence_ref(evidence) do
    encoded = evidence |> canonical_json() |> Jason.encode_to_iodata!()

    if :erlang.iolist_size(encoded) <= @max_evidence_bytes do
      {:ok, "sha256:" <> sha256(encoded)}
    else
      :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp canonical_json(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, nested} -> {key, canonical_json(nested)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonical_json(value) when is_list(value), do: Enum.map(value, &canonical_json/1)
  defp canonical_json(value), do: value

  defp exact_envelope(result, atom_fields) when is_map(result) and not is_struct(result) do
    atom_keys = MapSet.new(atom_fields)
    string_fields = Enum.map(atom_fields, &Atom.to_string/1)
    string_keys = MapSet.new(string_fields)
    actual = Map.keys(result) |> MapSet.new()

    cond do
      map_size(result) != length(atom_fields) ->
        :error

      actual == atom_keys ->
        {:ok, Map.new(atom_fields, fn field -> {field, Map.fetch!(result, field)} end), :atom}

      actual == string_keys ->
        {:ok,
         Map.new(atom_fields, fn field -> {field, Map.fetch!(result, Atom.to_string(field))} end),
         :string}

      true ->
        :error
    end
  end

  defp exact_envelope(_result, _fields), do: :error

  defp exact_string_object(value, fields) when is_map(value) and not is_struct(value) do
    if map_size(value) == length(fields) and MapSet.new(Map.keys(value)) == MapSet.new(fields) do
      {:ok, value}
    else
      :error
    end
  end

  defp exact_string_object(_value, _fields), do: :error

  defp exact_styled_object(value, atom_fields, :atom),
    do: exact_atom_object(value, atom_fields)

  defp exact_styled_object(value, atom_fields, :string) do
    with {:ok, string_values} <-
           exact_string_object(value, Enum.map(atom_fields, &Atom.to_string/1)) do
      {:ok, Map.new(atom_fields, fn field -> {field, string_values[Atom.to_string(field)]} end)}
    end
  end

  defp exact_atom_object(value, fields) when is_map(value) and not is_struct(value) do
    if map_size(value) == length(fields) and MapSet.new(Map.keys(value)) == MapSet.new(fields) do
      {:ok, value}
    else
      :error
    end
  end

  defp exact_atom_object(_value, _fields), do: :error

  defp bounded_string_list?(value, maximum_count, maximum_bytes),
    do: match?({:ok, _}, normalize_string_list(value, maximum_count, maximum_bytes))

  defp ordered_unique?(values) when is_list(values),
    do: values == Enum.sort(values) and values == Enum.uniq(values)

  defp ordered_unique?(_values), do: false

  defp normalize_string_list(value, maximum_count, maximum_bytes) do
    with {:ok, entries} <- bounded_list(value, maximum_count, & &1),
         true <- Enum.all?(entries, &bounded_text?(&1, maximum_bytes)) do
      {:ok, entries}
    else
      _other -> :error
    end
  end

  defp bounded_list(list, maximum_count, mapper)
       when is_list(list) and is_integer(maximum_count) and maximum_count >= 0 do
    do_bounded_list(list, maximum_count, mapper, [])
  end

  defp bounded_list(_list, _maximum_count, _mapper), do: :error

  defp do_bounded_list([], _remaining, _mapper, acc), do: {:ok, Enum.reverse(acc)}
  defp do_bounded_list([_head | _tail], 0, _mapper, _acc), do: :error

  defp do_bounded_list([head | tail], remaining, mapper, acc),
    do: do_bounded_list(tail, remaining - 1, mapper, [mapper.(head) | acc])

  defp do_bounded_list(_improper, _remaining, _mapper, _acc), do: :error

  defp map_list(list, mapper) do
    Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
      case mapper.(value) do
        {:ok, mapped} -> {:cont, {:ok, [mapped | acc]}}
        _error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  defp normalize_observed_at(observed_at) do
    case Diagnostic.new(%{
           version: Diagnostic.schema_version(),
           gate_id: "candidate.verification.timestamp",
           phase: "validation",
           decision: "blocked",
           code: "timestamp_probe",
           observed_at: observed_at
         }) do
      {:ok, diagnostic} -> {:ok, diagnostic.observed_at}
      _error -> {:error, :invalid_observed_at}
    end
  end

  defp fail_closed_if_outer_inputs_valid(program, candidate_tree_oid, observed_at) do
    with :ok <- ValidationProgram.validate(program),
         true <- valid_oid?(candidate_tree_oid),
         {:ok, observed_at} <- normalize_observed_at(observed_at) do
      invalid_evidence_report(
        program["profile_id"],
        "git-tree:" <> candidate_tree_oid,
        observed_at
      )
    else
      {:error, :invalid_validation_program} -> {:error, :invalid_validation_program}
      {:error, :invalid_observed_at} -> {:error, :invalid_observed_at}
      false -> {:error, :invalid_candidate_tree_oid}
      _other -> {:error, :invalid_validation_program}
    end
  end

  defp valid_exit_code?(value), do: is_integer(value) and value >= 0 and value <= 255
  defp valid_optional_exit_code?(nil), do: true
  defp valid_optional_exit_code?(value), do: valid_exit_code?(value)

  defp bounded_binary?(value, maximum),
    do: is_binary(value) and byte_size(value) <= maximum

  defp bounded_text?(value, maximum) do
    is_binary(value) and byte_size(value) > 0 and byte_size(value) <= maximum and
      String.valid?(value) and not String.contains?(value, <<0>>)
  end

  defp valid_sha256?(value),
    do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp valid_oid?(value),
    do: is_binary(value) and Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, value)

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
