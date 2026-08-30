defmodule Arbor.Orchestrator.CodingPlan.CodingRunRecoveryCoreTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Orchestrator.CodingPlan.CodingRunRecoveryCore

  test "classifies retryable unavailable separately from HMAC tamper" do
    assert CodingRunRecoveryCore.classify_resume_error(:journal_unavailable) ==
             :retryable_unavailable

    assert CodingRunRecoveryCore.classify_resume_error(:authentication_unavailable) ==
             :retryable_unavailable

    assert CodingRunRecoveryCore.classify_resume_error(:checkpoint_hmac_invalid,
             secret_derived?: true
           ) == :denial_or_tamper

    assert CodingRunRecoveryCore.classify_resume_error(:tampered, secret_derived?: true) ==
             :denial_or_tamper

    assert CodingRunRecoveryCore.classify_resume_error(:principal_mismatch) == :denial_or_tamper
    assert CodingRunRecoveryCore.classify_resume_error(:graph_changed) == :denial_or_tamper
  end

  test "HMAC without a derived secret is not treated as startup unavailability once classified denial" do
    assert CodingRunRecoveryCore.classify_resume_error(:checkpoint_hmac_invalid) ==
             :denial_or_tamper
  end

  test "admit requires exact task/run/principal/graph/artifact identity" do
    binding = valid_binding()

    record = %{
      run_id: "task_1",
      execution_principal: "agent_1",
      graph_hash: binding["graph_hash"]
    }

    compilation = %{
      "graph_hash" => binding["graph_hash"],
      "artifact_identity" => binding["artifact_identity"],
      "compiler_version" => binding["compiler_version"]
    }

    assert :ok = CodingRunRecoveryCore.admit(binding, record, compilation, "agent_1")

    assert {:error, :binding_mismatch} =
             CodingRunRecoveryCore.admit(binding, record, compilation, "agent_other")

    assert {:error, :binding_mismatch} =
             CodingRunRecoveryCore.admit(
               %{binding | "graph_hash" => String.duplicate("b", 64)},
               record,
               compilation,
               "agent_1"
             )
  end

  test "idempotence key is digest-bound and stable" do
    key =
      CodingRunRecoveryCore.idempotence_key(
        "task_1",
        "task_1",
        String.duplicate("a", 64),
        String.duplicate("c", 64),
        "success"
      )

    assert key ==
             CodingRunRecoveryCore.idempotence_key(
               "task_1",
               "task_1",
               String.duplicate("a", 64),
               String.duplicate("c", 64),
               "success"
             )

    refute key ==
             CodingRunRecoveryCore.idempotence_key(
               "task_1",
               "task_1",
               String.duplicate("a", 64),
               String.duplicate("c", 64),
               "failed"
             )
  end

  test "utf8_truncate is byte-bounded and rejects invalid UTF-8" do
    assert CodingRunRecoveryCore.utf8_truncate("abc", 2) == "ab"
    assert CodingRunRecoveryCore.utf8_truncate("éé", 2) == "é"
    assert CodingRunRecoveryCore.utf8_truncate(<<0xFF, 0xFE>>, 8) == ""
  end

  test "closed binding rejects type and hash violations" do
    binding = valid_binding()
    assert :ok = CodingRunRecoveryCore.closed_binding?(binding)

    assert {:error, :invalid_binding} =
             CodingRunRecoveryCore.closed_binding?(Map.put(binding, "graph_hash", "nope"))

    assert {:error, :invalid_binding} =
             CodingRunRecoveryCore.closed_binding?(Map.put(binding, "extra", "x"))
  end

  test "admit_receipt recomputes the framed idempotence key" do
    binding = valid_binding()

    record = %{
      run_id: "task_1",
      execution_principal: "agent_1",
      graph_hash: binding["graph_hash"]
    }

    compilation = %{
      "graph_hash" => binding["graph_hash"],
      "artifact_identity" => binding["artifact_identity"],
      "compiler_version" => binding["compiler_version"]
    }

    receipt = closed_receipt(binding, "success")
    assert :ok = CodingRunRecoveryCore.admit_receipt(receipt, binding, record, compilation)

    assert {:error, :binding_mismatch} =
             CodingRunRecoveryCore.admit_receipt(
               %{receipt | "idempotence_key" => String.duplicate("e", 64)},
               binding,
               record,
               compilation
             )
  end

  test "adapter-input digest is compact-canonical and closed" do
    adapter = valid_adapter()
    assert :ok = CodingRunRecoveryCore.closed_adapter_input?(adapter)
    assert {:ok, digest} = CodingRunRecoveryCore.adapter_input_digest(adapter)
    assert byte_size(digest) == 64

    assert {:error, :invalid_adapter_input} =
             CodingRunRecoveryCore.closed_adapter_input?(Map.put(adapter, "extra", "x"))
  end

  test "decision and receipt identity join recomputes binding and decision digests" do
    binding = valid_binding()
    {:ok, binding_digest} = CodingRunRecoveryCore.binding_digest(binding)
    adapter = valid_adapter()
    {:ok, adapter_digest} = CodingRunRecoveryCore.adapter_input_digest(adapter)
    {:ok, program_digest} = CodingRunRecoveryCore.program_digest(adapter["program"])

    unsigned = %{
      "schema_version" => 1,
      "task_id" => binding["task_id"],
      "run_id" => binding["run_id"],
      "agent_id" => binding["agent_id"],
      "execution_principal" => binding["execution_principal"],
      "control_principal_id" => binding["control_principal_id"],
      "executor_kind" => binding["executor_kind"],
      "graph_hash" => binding["graph_hash"],
      "artifact_identity" => binding["artifact_identity"],
      "canonical_status" => "change_committed",
      "final_outcome_status" => "success",
      "validation_requirement" => "required",
      "program_digest" => program_digest,
      "candidate_tree_oid" => adapter["candidate_tree_oid"],
      "observed_at" => adapter["observed_at"],
      "adapter_input_digest" => adapter_digest,
      "binding_digest" => binding_digest,
      "decision_digest" => String.duplicate("0", 64)
    }

    {:ok, decision_digest} = CodingRunRecoveryCore.decision_digest(unsigned)
    decision = Map.put(unsigned, "decision_digest", decision_digest)
    assert :ok = CodingRunRecoveryCore.closed_decision?(decision)
    assert :ok = CodingRunRecoveryCore.admit_decision(decision, binding)

    receipt =
      closed_receipt(binding, "success")
      |> Map.put("coding_status", "change_committed")
      |> Map.put("canonical_status", "change_committed")
      |> Map.put("adapter_input_digest", adapter_digest)
      |> Map.put("decision_digest", decision_digest)
      |> Map.put(
        "idempotence_key",
        CodingRunRecoveryCore.idempotence_key(
          binding["task_id"],
          binding["run_id"],
          binding["graph_hash"],
          binding["artifact_identity"],
          "change_committed"
        )
      )

    assert :ok = CodingRunRecoveryCore.admit_terminal_identity(binding, decision, receipt)
    assert :ok = CodingRunRecoveryCore.admit_adapter_input(decision, adapter)

    assert {:error, :binding_mismatch} =
             CodingRunRecoveryCore.admit_executor_result(receipt, decision, %{
               "status" => "no_changes"
             })
  end

  test "canonical_json rejects atom keys and non-JSON values" do
    assert {:error, :invalid_json} = CodingRunRecoveryCore.canonical_json(%{a: 1})
    assert {:error, :invalid_json} = CodingRunRecoveryCore.canonical_json(%{"a" => :atom})
    assert {:ok, _} = CodingRunRecoveryCore.canonical_json(%{"a" => 1, "b" => [true, nil, "x"]})
  end

  test "producer_evidence_state treats dropped non-JSON and atom-keyed maps as partial" do
    assert :none = CodingRunRecoveryCore.producer_evidence_state(nil, nil, nil, nil)
    assert :none = CodingRunRecoveryCore.producer_evidence_state("", "", "", nil)

    assert :partial =
             CodingRunRecoveryCore.producer_evidence_state(self(), nil, nil, nil)

    tree = String.duplicate("a", 40)
    observed = "2026-07-22T12:00:00.000Z"
    result = %{"passed" => true}

    assert :partial =
             CodingRunRecoveryCore.producer_evidence_state(
               %{profile_id: "default"},
               tree,
               observed,
               result
             )

    assert :complete =
             CodingRunRecoveryCore.producer_evidence_state(
               %{"profile_id" => "default"},
               tree,
               observed,
               result
             )
  end

  test "tri-state: reviewed none is not_applicable; complete is required; partial fails closed" do
    binding = valid_binding()
    {:ok, binding_digest} = CodingRunRecoveryCore.binding_digest(binding)

    none = %{
      "schema_version" => 1,
      "task_id" => binding["task_id"],
      "run_id" => binding["run_id"],
      "agent_id" => binding["agent_id"],
      "execution_principal" => binding["execution_principal"],
      "control_principal_id" => binding["control_principal_id"],
      "executor_kind" => binding["executor_kind"],
      "graph_hash" => binding["graph_hash"],
      "artifact_identity" => binding["artifact_identity"],
      "canonical_status" => "human_review_required",
      "final_outcome_status" => "success",
      "validation_requirement" => "not_applicable",
      "program_digest" => "",
      "candidate_tree_oid" => "",
      "observed_at" => "",
      "adapter_input_digest" => "",
      "binding_digest" => binding_digest,
      "decision_digest" => String.duplicate("0", 64)
    }

    {:ok, digest} = CodingRunRecoveryCore.decision_digest(none)
    none = Map.put(none, "decision_digest", digest)
    assert :none = CodingRunRecoveryCore.evidence_state(none)

    assert {:ok, "not_applicable"} =
             CodingRunRecoveryCore.expected_requirement("human_review_required", :none)

    assert :ok = CodingRunRecoveryCore.closed_decision?(none)

    hex = String.duplicate("a", 64)
    partial = %{none | "program_digest" => hex, "validation_requirement" => "not_applicable"}
    {:ok, partial_digest} = CodingRunRecoveryCore.decision_digest(partial)
    partial = Map.put(partial, "decision_digest", partial_digest)
    assert :partial = CodingRunRecoveryCore.evidence_state(partial)

    assert {:error, :partial_validation_evidence} =
             CodingRunRecoveryCore.expected_requirement("human_review_required", :partial)

    assert {:error, :invalid_decision} = CodingRunRecoveryCore.closed_decision?(partial)

    labeled_required = %{partial | "validation_requirement" => "required"}
    {:ok, labeled_digest} = CodingRunRecoveryCore.decision_digest(labeled_required)
    labeled_required = Map.put(labeled_required, "decision_digest", labeled_digest)
    assert {:error, :invalid_decision} = CodingRunRecoveryCore.closed_decision?(labeled_required)

    assert {:error, :missing_validation_evidence} =
             CodingRunRecoveryCore.expected_requirement("change_committed", :none)

    assert {:error, :invalid_decision} =
             CodingRunRecoveryCore.closed_decision?(%{
               none
               | "canonical_status" => "change_committed",
                 "validation_requirement" => "not_applicable"
             })
  end

  test "not_applicable rejects leftover hex digests and status-only helper is not admission" do
    assert CodingRunRecoveryCore.validation_requirement("human_review_required") ==
             "not_applicable"

    assert CodingRunRecoveryCore.validation_requirement("change_committed") == "required"

    assert {:ok, "required"} =
             CodingRunRecoveryCore.expected_requirement("change_committed", :complete)
  end

  test "pipeline errors never admit current or stale validation as acceptance evidence" do
    assert {:ok, "not_applicable"} =
             CodingRunRecoveryCore.expected_requirement("pipeline_error", :none)

    assert {:ok, "not_applicable"} =
             CodingRunRecoveryCore.expected_requirement("pipeline_error", :complete)

    assert {:ok, "not_applicable"} =
             CodingRunRecoveryCore.expected_requirement("pipeline_error", :partial)
  end

  test "combine_close_result never embeds a resume value or authority" do
    value = %{context: %{"prose" => "secret"}, final_outcome: %{status: :success}}

    assert {:error, {:authority_close_failed, :forced, :resume_succeeded}} =
             CodingRunRecoveryCore.combine_close_result({:error, :forced}, {:ok, value})

    refute match?(
             {:error, {:authority_close_failed, _, {:ok, _}}},
             CodingRunRecoveryCore.combine_close_result({:error, :forced}, {:ok, value})
           )

    assert {:error, {:authority_close_failed, :forced, :principal_mismatch}} =
             CodingRunRecoveryCore.combine_close_result(
               {:error, :forced},
               {:error, :principal_mismatch}
             )

    assert CodingRunRecoveryCore.bounded_close_cause(%{context: "prose"}) ==
             :unprovable_recovery

    assert CodingRunRecoveryCore.bounded_close_cause(self()) == :unprovable_recovery
  end

  @tag :security_regression
  test "security regression: bounded_close_cause does not preserve deep or aggregate-unbounded tuples" do
    deep =
      {:layer, {:layer, {:layer, {:layer, :forced}}}}

    assert CodingRunRecoveryCore.bounded_close_cause(deep) ==
             {:layer, {:layer, :unprovable_recovery}}

    huge = String.duplicate("x", 300)

    assert CodingRunRecoveryCore.bounded_close_cause(
             {:wide, huge, huge, {:wide, huge, huge, huge}}
           ) == :unprovable_recovery

    assert {:error, {:authority_close_failed, :forced, :resume_succeeded}} =
             CodingRunRecoveryCore.combine_close_result({:error, :forced}, {:ok, %{}})
  end

  test "adapter program with atom keys is invalid" do
    adapter = valid_adapter()
    bad = %{adapter | "program" => %{profile_id: "default"}}
    assert {:error, :invalid_adapter_input} = CodingRunRecoveryCore.closed_adapter_input?(bad)
  end

  defp valid_adapter do
    %{
      "schema_version" => 1,
      "task_id" => "task_1",
      "run_id" => "task_1",
      "program" => %{"profile_id" => "default", "result_adapter" => "mix_compile_v1"},
      "candidate_tree_oid" => String.duplicate("a", 40),
      "action_result" => %{"passed" => true, "exit_code" => 0},
      "observed_at" => "2026-07-22T12:00:00.000Z"
    }
  end

  defp closed_receipt(binding, status) do
    %{
      "schema_version" => 1,
      "task_id" => binding["task_id"],
      "run_id" => binding["run_id"],
      "execution_principal" => binding["execution_principal"],
      "control_principal_id" => binding["control_principal_id"],
      "graph_hash" => binding["graph_hash"],
      "artifact_identity" => binding["artifact_identity"],
      "idempotence_key" =>
        CodingRunRecoveryCore.idempotence_key(
          binding["task_id"],
          binding["run_id"],
          binding["graph_hash"],
          binding["artifact_identity"],
          status
        ),
      "final_outcome_status" => status,
      "coding_status" => status,
      "canonical_status" => status,
      "error" => "",
      "worker_provider" => "grok",
      "requested_model" => "",
      "confirmed_model" => "",
      "delivery_state" => "",
      "completion_state" => "",
      "worker_session_id" => "",
      "worker_provider_session_id" => "",
      "workspace_id" => "",
      "branch" => "",
      "base_commit" => "",
      "commit" => "",
      "commit_hash" => "",
      "workspace_release_status" => "",
      "plan_digest" => "",
      "pipeline_digest" => binding["graph_hash"],
      "manifest_digest" => "",
      "node_failure_reasons" => %{},
      "adapter_input_digest" => "",
      "decision_digest" => String.duplicate("e", 64)
    }
  end

  defp valid_binding do
    hash = String.duplicate("a", 64)
    identity = String.duplicate("c", 64)

    %{
      "schema_version" => 1,
      "task_id" => "task_1",
      "run_id" => "task_1",
      "agent_id" => "agent_1",
      "execution_principal" => "agent_1",
      "control_principal_id" => "caller_1",
      "executor_kind" => "coding_change",
      "graph_hash" => hash,
      "compiler_version" => "1",
      "artifact_identity" => identity
    }
  end
end
