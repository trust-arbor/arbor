defmodule Arbor.Orchestrator.CodingPlan.OperatorCandidateVerifierTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Coding.{Plan, VerificationReport, WorkPacket}
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Common.SafePath
  alias Arbor.Orchestrator.CodingPlan.{ArtifactStore, OperatorCandidateVerifier}
  alias Arbor.Orchestrator.Config
  alias Arbor.Security
  alias Arbor.Security.SigningAuthorityBroker

  @moduletag :fast
  @moduletag :candidate_verification_surface

  @observed_at "2026-07-23T12:00:00Z"
  @candidate_tree_oid String.duplicate("a", 40)
  @task_id "task_operator_candidate_test"
  @workspace_id "workspace_operator_candidate_test"

  defmodule TestActionsExecutor do
    def execute_structured(action, params, _workdir, opts) do
      config =
        Application.fetch_env!(
          :arbor_orchestrator,
          :operator_candidate_verifier_test_executor
        )

      authority = Keyword.fetch!(opts, :signing_authority)

      active =
        Arbor.Security.sign_with_authority(
          authority,
          "arbor://coding/operator-candidate-verifier-test"
        )

      send(
        config.observer,
        {:operator_candidate_executor, action, params, opts, authority, active}
      )

      execute(action, params, opts, config)
    end

    defp execute("coding_workspace_inspect", _params, _opts, %{mode: :timeout}) do
      mark_pending_approval()

      receive do
        :release_operator_candidate_verification -> {:error, :released}
      end
    end

    defp execute("coding_workspace_inspect", _params, _opts, %{mode: :inspection_error}),
      do: {:error, :workspace_not_found}

    defp execute("coding_workspace_inspect", _params, opts, %{
           mode: :task_mismatch,
           expected_task_id: expected_task_id
         }) do
      if Keyword.get(opts, :task_id) == expected_task_id,
        do: {:ok, inspection(expected_task_id)},
        else: {:error, :task_owner_mismatch}
    end

    defp execute("coding_workspace_inspect", _params, _opts, config) do
      {:ok, inspection(config.workspace_id)}
    end

    defp execute("mix_compile", _params, _opts, config) do
      stdout = "Compiling retained candidate\n"
      stderr = ""

      feedback = %{
        "exit_code" => 0,
        "passed" => true,
        "stdout_excerpt" => stdout,
        "stderr_excerpt" => stderr,
        "stdout_truncated" => false,
        "stderr_truncated" => false,
        "stdout_sha256" => sha256(stdout),
        "stderr_sha256" => sha256(stderr)
      }

      {:ok,
       %{
         "path" => config.worktree_path,
         "exit_code" => 0,
         "passed" => true,
         "reason" => nil,
         "stdout" => stdout,
         "stderr" => stderr,
         "feedback" => feedback,
         "feedback_json" => Jason.encode!(feedback),
         "validated_tree_oid" =>
           Arbor.Orchestrator.CodingPlan.OperatorCandidateVerifierTest.candidate_tree_oid(),
         "validated_head" => String.duplicate("b", 40),
         "termination" => nil
       }}
    end

    defp execute("coding_cross_app_validate", _params, _opts, _config) do
      check = cross_check()

      {:ok,
       %{
         "passed" => true,
         "reason" => "cross_app_validated",
         "base_commit" => String.duplicate("c", 40),
         "changed_files" => ["apps/arbor_orchestrator/lib/example.ex"],
         "changed_apps" => ["arbor_orchestrator"],
         "affected_apps" => ["arbor_orchestrator"],
         "test_paths" => ["apps/arbor_orchestrator/test"],
         "root_wide" => false,
         "compile" => check,
         "xref" => check,
         "test_compile" => check,
         "test" => check,
         "validated_tree_oid" =>
           Arbor.Orchestrator.CodingPlan.OperatorCandidateVerifierTest.candidate_tree_oid(),
         "validated_head" => String.duplicate("b", 40),
         "feedback_json" => Jason.encode!(%{"passed" => true})
       }}
    end

    defp execute("coding_contract_change_validate", _params, _opts, _config) do
      check = cross_check()

      {:ok,
       %{
         "passed" => true,
         "reason" => "contract_change_validated",
         "base_commit" => String.duplicate("c", 40),
         "changed_files" => ["apps/arbor_kernel/lib/arbor/contracts/coding/plan.ex"],
         "test_paths" => ["apps/arbor_kernel/test/arbor/contracts/admission_test.exs"],
         "preflight" => check,
         "test" => check,
         "validated_tree_oid" =>
           Arbor.Orchestrator.CodingPlan.OperatorCandidateVerifierTest.candidate_tree_oid(),
         "validated_head" => String.duplicate("b", 40),
         "feedback_json" => Jason.encode!(%{"passed" => true})
       }}
    end

    defp execute("coding_security_regression_validate", _params, _opts, %{
           mode: :validator_attestation_claimed
         }),
         do: {:error, :attestation_already_claimed}

    defp execute("coding_security_regression_validate", _params, _opts, %{
           mode: :validator_secret_map
         }),
         do: {:error, %{token: "must-not-leak"}}

    defp execute("coding_security_regression_validate", _params, _opts, _config) do
      candidate = security_leg(0, 1, 0)
      base = security_leg(1, 0, 1)
      digest = String.duplicate("d", 64)
      source_digest = String.duplicate("e", 64)
      path = "apps/arbor_orchestrator/test/operator_candidate_security_regression_test.exs"

      {:ok,
       %{
         "passed" => true,
         "reason" => "security_regression_validated",
         "base_commit" => String.duplicate("c", 40),
         "candidate_fingerprint" => digest,
         "test_paths" => [path],
         "source_hashes" => [%{"path" => path, "sha256" => source_digest}],
         "candidate" => candidate,
         "base" => base,
         "diagnostics" => %{
           "candidate" => security_diagnostic(candidate, digest),
           "base" => security_diagnostic(base, digest)
         },
         "evidence_type" => "reviewed_regression_evidence",
         "attested_base_commit" => String.duplicate("c", 40),
         "attested_candidate_commit" => String.duplicate("b", 40),
         "attested_candidate_tree_oid" =>
           Arbor.Orchestrator.CodingPlan.OperatorCandidateVerifierTest.candidate_tree_oid(),
         "attested_diff_sha256" => digest,
         "attested_selected_tests" => [
           %{"path" => path, "blob_sha256" => source_digest}
         ],
         "review_attestation_digest" => digest,
         "council_decision_digest" => source_digest,
         "feedback_json" => Jason.encode!(%{"passed" => true}),
         "termination" => nil
       }}
    end

    defp execute(_validation_action, _params, _opts, _config),
      do: {:error, :unsupported_validation_fixture}

    defp inspection(workspace_id) do
      config =
        Application.fetch_env!(
          :arbor_orchestrator,
          :operator_candidate_verifier_test_executor
        )

      %{
        "exists" => true,
        "workspace_id" => workspace_id,
        "committable_tree_oid" =>
          Arbor.Orchestrator.CodingPlan.OperatorCandidateVerifierTest.candidate_tree_oid(),
        "committable_tree_observed_at" =>
          Arbor.Orchestrator.CodingPlan.OperatorCandidateVerifierTest.observed_at(),
        "worktree_path" => config.worktree_path
      }
    end

    defp mark_pending_approval do
      case Application.get_env(
             :arbor_orchestrator,
             :operator_candidate_verifier_test_approval
           ) do
        %{state: state} when is_pid(state) -> Agent.update(state, &Map.put(&1, :pending, true))
        _ -> :ok
      end
    end

    defp sha256(value) do
      value
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    end

    defp cross_check do
      %{
        "status" => "completed",
        "passed" => true,
        "exit_code" => 0,
        "reason" => nil,
        "stdout_excerpt" => "validation passed",
        "stderr_excerpt" => "",
        "stdout_truncated" => false,
        "stderr_truncated" => false,
        "stdout_sha256" => String.duplicate("d", 64),
        "stderr_sha256" => String.duplicate("e", 64)
      }
    end

    defp security_leg(exit_code, passed, test_failures) do
      %{
        "completed" => true,
        "status" => "completed",
        "exit_code" => exit_code,
        "timed_out" => false,
        "executed" => 1,
        "passed" => passed,
        "test_failures" => test_failures,
        "setup_failures" => 0,
        "skipped" => 0,
        "excluded" => 0,
        "invalid" => 0
      }
    end

    defp security_diagnostic(leg, digest) do
      %{
        "exit_code" => leg["exit_code"],
        "timed_out" => leg["timed_out"],
        "output_bytes" => 18,
        "output_sha256" => digest,
        "untrusted_diagnostic_output" => ""
      }
    end
  end

  defmodule TestResourceFacade do
    def admit_security_regression_operator_attestation(attestation_id, proof, opts) do
      config =
        Application.fetch_env!(
          :arbor_orchestrator,
          :operator_candidate_verifier_test_resource
        )

      send(config.observer, {:operator_candidate_admit, attestation_id, proof, opts})

      case Map.get(config, :admit_error) do
        nil ->
          admit_from_config(config, attestation_id, proof, opts)

        reason ->
          {:error, reason}
      end
    end

    defp admit_from_config(config, attestation_id, proof, opts) do
      case Map.get(config, :attestations) do
        pid when is_pid(pid) ->
          Agent.get_and_update(pid, fn state ->
            admit_from_state(state, attestation_id, proof, opts, config)
          end)

        _missing ->
          {:ok, %{review_attestation_id: attestation_id}}
      end
    end


    defp admit_from_state(state, attestation_id, proof, opts, config) do
      task_id = Keyword.get(opts, :task_id)
      principal_id = Keyword.get(opts, :principal_id)

      case Map.fetch(state, attestation_id) do
        :error ->
          {{:error, :not_found}, state}

        {:ok, record} ->
          if record.task_id == task_id and record.principal_id == principal_id and
               record.workspace_id == config.workspace_id do
            walk_state(state, attestation_id, proof, MapSet.new())
          else
            {{:error, :not_authorized}, state}
          end
      end
    end

    defp walk_state(state, id, proof, seen) do
      cond do
        MapSet.member?(seen, id) ->
          {{:error, :successor_lineage_mismatch}, state}

        MapSet.size(seen) >= 4 ->
          {{:error, :retry_budget_exhausted}, state}

        true ->
          case Map.fetch(state, id) do
            :error ->
              {{:error, :not_found}, state}

            {:ok, record} ->
              decide_test_node(state, id, record, proof, MapSet.put(seen, id))
          end
      end
    end

    defp decide_test_node(state, id, record, proof, seen) do
      cond do
        record.status == :available ->
          {{:ok, %{review_attestation_id: id}}, state}

        record.status == :revoked ->
          {{:error, :attestation_revoked}, state}

        is_binary(record.successor_id) ->
          walk_state(state, record.successor_id, proof, seen)

        record.retry_index >= 3 ->
          {{:error, :retry_budget_exhausted}, state}

        record.capacity_evidence != nil or first_hop_proof?(record, proof) ->
          mint_test_successor(state, id, record)

        record.predecessor_id == nil ->
          {{:error, :attestation_already_claimed}, state}

        true ->
          {{:error, :capacity_retry_denied}, state}
      end
    end

    defp first_hop_proof?(record, proof) when is_map(proof) do
      record.predecessor_id == nil and record.successor_id == nil and
        proof["kind"] == "archived_security_regression_capacity" and
        proof["terminal_status"] == "validation_capacity_exceeded"
    end

    defp first_hop_proof?(_record, _proof), do: false

    defp mint_test_successor(state, parent_id, parent) do
      child_id =
        "review_attestation_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

      parent = %{parent | successor_id: child_id}

      child = %{
        status: :available,
        predecessor_id: parent_id,
        successor_id: nil,
        retry_index: parent.retry_index + 1,
        origin: :capacity_retry,
        capacity_evidence: nil,
        task_id: parent.task_id,
        principal_id: parent.principal_id,
        workspace_id: parent.workspace_id
      }

      state =
        state
        |> Map.put(parent_id, parent)
        |> Map.put(child_id, child)

      {{:ok, %{review_attestation_id: child_id}}, state}
    end

    def coding_resource_inventory(opts) do
      config =
        Application.fetch_env!(
          :arbor_orchestrator,
          :operator_candidate_verifier_test_resource
        )

      task_id = Keyword.fetch!(opts, :task_id)
      principal_id = Keyword.fetch!(opts, :principal_id)

      send(config.observer, {:operator_candidate_resource_inventory, opts})

      resource = resource(config, %{})

      additional_resources =
        config
        |> Map.get(:additional_resources, [])
        |> Enum.map(&resource(config, &1))

      resources = [resource | additional_resources]

      {:ok,
       %{
         "schema_version" => 1,
         "journal" => %{"status" => "complete", "quarantined" => false},
         "filters" => %{"task_id" => task_id, "principal_id" => principal_id},
         "max_items" => Keyword.fetch!(opts, :max_items),
         "truncated" => false,
         "counts" => %{
           "matching" => length(resources),
           "returned" => length(resources),
           "truncated" => 0
         },
         "resources" => resources
       }}
    end

    defp resource(config, overrides) do
      config = Map.merge(config, Map.new(overrides))

      {resource_type, active} =
        case config.state do
          :active -> {"live_workspace_lease", true}
          :retained -> {"retained_workspace_record", false}
        end

      %{
        "resource_type" => resource_type,
        "resource_id" => config.workspace_id,
        "workspace_id" => config.workspace_id,
        "task_id" => config.task_id,
        "principal_id" => config.principal_id,
        "repo_path" => config.repo_path,
        "worktree_path" => config.worktree_path,
        "branch" => "arbor/operator-candidate-verifier-test",
        "base_commit" => String.duplicate("c", 40),
        "lifecycle" => if(active, do: "active", else: "retained"),
        "active" => active,
        "cleanup_armed" => true
      }
    end

    def reactivate_retained_coding_workspace(workspace_id, task_id, principal_id) do
      config =
        Application.fetch_env!(
          :arbor_orchestrator,
          :operator_candidate_verifier_test_resource
        )

      if workspace_id == config.workspace_id and task_id == config.task_id and
           principal_id == config.principal_id do
        send(
          config.observer,
          {:operator_candidate_workspace_reactivated, workspace_id, task_id, principal_id}
        )

        {:ok,
         %{
           workspace_id: workspace_id,
           task_id: task_id,
           principal_id: principal_id,
           repo_path: Map.get(config, :lease_repo_path, config.repo_path),
           worktree_path: config.worktree_path
         }}
      else
        {:error, :retained_workspace_not_authorized}
      end
    end
  end

  defmodule TestApprovalFacade do
    def cleanup_approvals_for_task(task_id, opts) do
      config = approval_config()
      send(config.observer, {:operator_candidate_approval_cleanup, task_id, opts})
      Process.sleep(Map.get(config, :cleanup_delay_ms, 0))

      case Map.get(config, :cleanup_result, :ok) do
        :ok ->
          Agent.update(config.state, &Map.put(&1, :pending, false))
          :ok

        other ->
          other
      end
    end

    def pending_approval_inventory(opts) do
      config = approval_config()
      state = Agent.get(config.state, & &1)
      scope = Keyword.get(opts, :principal_scope, :participant)

      pending? =
        state.pending or
          (scope == :participant and Map.get(state, :approver_only_pending, false))

      matching = if pending?, do: 1, else: 0
      send(config.observer, {:operator_candidate_approval_inventory, opts})

      {:ok,
       %{
         "schema_version" => 1,
         "filters" => %{
           "task_id" => Keyword.fetch!(opts, :task_id),
           "principal_id" => Keyword.fetch!(opts, :principal_id),
           "principal_scope" => Atom.to_string(scope)
         },
         "truncated" => false,
         "counts" => %{
           "matching" => matching,
           "returned" => matching,
           "truncated" => 0,
           "backend_omitted" => 0,
           "quarantined" => 0
         },
         "approvals" => []
       }}
    end

    defp approval_config do
      Application.fetch_env!(
        :arbor_orchestrator,
        :operator_candidate_verifier_test_approval
      )
    end
  end

  defmodule LeakySecurity do
    def load_signing_key(_agent_id), do: {:error, {:private_key, "must-not-cross-boundary"}}
    def build_signing_authority_acquisition_proof(_agent_id, _private_key, _opts), do: :unused
    def open_signing_authority(_proof), do: :unused
    def close_signing_authority(_authority), do: :ok
  end

  defmodule DelayedCloseSecurity do
    def load_signing_key(agent_id), do: Arbor.Security.load_signing_key(agent_id)

    def build_signing_authority_acquisition_proof(agent_id, private_key, opts) do
      Arbor.Security.build_signing_authority_acquisition_proof(agent_id, private_key, opts)
    end

    def open_signing_authority(proof), do: Arbor.Security.open_signing_authority(proof)

    def close_signing_authority(authority) do
      delay =
        :arbor_orchestrator
        |> Application.fetch_env!(:operator_candidate_verifier_test_approval)
        |> Map.get(:authority_close_delay_ms, 0)

      Process.sleep(delay)
      Arbor.Security.close_signing_authority(authority)
    end
  end

  defmodule TestTerminalEvidenceStore do
    def read_task_compilation(base_root, task_id) do
      ArtifactStore.read_task_compilation(base_root, task_id)
    end

    def read_terminal_evidence(base_root, task_id) do
      case Application.get_env(
             :arbor_orchestrator,
             :operator_candidate_verifier_test_terminal_read
           ) do
        :raise ->
          raise "stub-terminal-reader-secret"

        :exit ->
          exit(:stub_terminal_reader_exit)

        :unexpected_ok ->
          {:ok, ["not-an-object"]}

        :unexpected_error ->
          {:error, :enoent}

        :other ->
          :not_a_result_tuple

        _default ->
          ArtifactStore.read_terminal_evidence(base_root, task_id)
      end
    end
  end

  def candidate_tree_oid, do: @candidate_tree_oid
  def observed_at, do: @observed_at

  setup do
    ensure_authority_stack!()

    previous = %{
      security_module: Application.get_env(:arbor_orchestrator, :security_module),
      actions_executor:
        Application.get_env(:arbor_orchestrator, :coding_candidate_actions_executor),
      logs_root: Application.get_env(:arbor_orchestrator, :coding_pipeline_logs_root),
      resource_facade:
        Application.get_env(:arbor_orchestrator, :coding_reconciliation_resource_facade),
      approval_facade:
        Application.get_env(:arbor_orchestrator, :coding_reconciliation_approval_facade),
      test_resource:
        Application.get_env(
          :arbor_orchestrator,
          :operator_candidate_verifier_test_resource
        ),
      test_approval:
        Application.get_env(
          :arbor_orchestrator,
          :operator_candidate_verifier_test_approval
        ),
      test_executor:
        Application.get_env(
          :arbor_orchestrator,
          :operator_candidate_verifier_test_executor
        )
    }

    Application.put_env(:arbor_orchestrator, :security_module, Security)

    Application.put_env(
      :arbor_orchestrator,
      :coding_candidate_actions_executor,
      TestActionsExecutor
    )

    logs_root =
      Path.join(
        System.tmp_dir!(),
        "operator-candidate-provenance-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(logs_root)
    {:ok, logs_root} = SafePath.resolve_real(logs_root)

    repo_path = Path.join(logs_root, "repo")
    worktree_path = Path.join(logs_root, "worktree")
    File.mkdir_p!(repo_path)
    File.mkdir_p!(worktree_path)

    Application.put_env(:arbor_orchestrator, :coding_pipeline_logs_root, logs_root)

    Application.put_env(
      :arbor_orchestrator,
      :coding_reconciliation_resource_facade,
      TestResourceFacade
    )

    Application.put_env(
      :arbor_orchestrator,
      :coding_reconciliation_approval_facade,
      TestApprovalFacade
    )

    {:ok, approval_state} =
      Agent.start_link(fn -> %{pending: false, approver_only_pending: false} end)

    {:ok, identity} =
      Identity.generate(
        name: "operator-candidate-#{System.unique_integer([:positive, :monotonic])}"
      )

    :ok = Security.register_identity(Identity.public_only(identity))
    :ok = Security.store_signing_key(identity.agent_id, identity.private_key)

    on_exit(fn ->
      _ = Security.delete_signing_key(identity.agent_id)
      _ = Security.deregister_identity(identity.agent_id)

      restore_env(
        :arbor_orchestrator,
        :security_module,
        previous.security_module
      )

      restore_env(
        :arbor_orchestrator,
        :coding_candidate_actions_executor,
        previous.actions_executor
      )

      restore_env(:arbor_orchestrator, :coding_pipeline_logs_root, previous.logs_root)

      restore_env(
        :arbor_orchestrator,
        :coding_reconciliation_resource_facade,
        previous.resource_facade
      )

      restore_env(
        :arbor_orchestrator,
        :coding_reconciliation_approval_facade,
        previous.approval_facade
      )

      restore_env(
        :arbor_orchestrator,
        :operator_candidate_verifier_test_resource,
        previous.test_resource
      )

      restore_env(
        :arbor_orchestrator,
        :operator_candidate_verifier_test_approval,
        previous.test_approval
      )

      restore_env(
        :arbor_orchestrator,
        :operator_candidate_verifier_test_executor,
        previous.test_executor
      )

      File.rm_rf(logs_root)
    end)

    Application.put_env(
      :arbor_orchestrator,
      :operator_candidate_verifier_test_resource,
      %{
        observer: self(),
        workspace_id: @workspace_id,
        task_id: @task_id,
        principal_id: identity.agent_id,
        repo_path: repo_path,
        worktree_path: worktree_path,
        additional_resources: [],
        state: :retained
      }
    )

    Application.put_env(
      :arbor_orchestrator,
      :operator_candidate_verifier_test_approval,
      %{
        observer: self(),
        state: approval_state,
        authority_close_delay_ms: 0,
        cleanup_delay_ms: 0
      }
    )

    configure_executor(:normal)

    %{
      agent_id: identity.agent_id,
      private_key: identity.private_key,
      approval_state: approval_state,
      logs_root: logs_root,
      repo_path: repo_path,
      worktree_path: worktree_path
    }
  end

  test "product and operator surfaces preserve the same gate IDs for every profile", ctx do
    for profile <- ~w[default cross_app security_regression contract_change] do
      plan = plan!(profile)
      program = compiled_program!(plan)
      request = request(ctx.agent_id, profile)

      {:ok, product_authority} =
        open_authority(ctx.agent_id, ctx.private_key, :operator_product_parity)

      product_result =
        try do
          Arbor.Orchestrator.verify_coding_candidate(
            candidate(program, profile),
            agent_id: ctx.agent_id,
            task_id: @task_id,
            signing_authority: product_authority
          )
        after
          :ok = Security.close_signing_authority(product_authority)
        end

      assert {:ok, product_report} = product_result

      assert {:ok, operator_report} =
               verify_operator(plan, request)

      assert Map.delete(operator_report, "provenance") == product_report
      assert operator_report["profile"] == profile
      assert operator_report["status"] == "passed"

      assert Enum.map(operator_report["diagnostics"], & &1["gate_id"]) ==
               expected_gate_ids(profile)
    end
  end

  test "genuine process-owned authority is closed after successful verification", ctx do
    assert {:ok, report} =
             verify_operator(plan!("default"), request(ctx.agent_id, "default"))

    assert_receive {:operator_candidate_executor, "coding_workspace_inspect", _params, _opts,
                    authority, {:ok, _signed_request}}

    assert {:error, :authority_not_found} =
             Security.sign_with_authority(authority, "after-success")

    assert {:ok, ^report} = VerificationReport.normalize(report)
    assert report["status"] == "passed"

    assert report["provenance"] == %{
             "version" => 1,
             "task_id" => @task_id,
             "workspace_id" => @workspace_id,
             "principal_id" => ctx.agent_id,
             "plan_fingerprint" => report["provenance"]["plan_fingerprint"],
             "plan_version" => 2,
             "validation_profile" => "default",
             "review_profile" => "binding",
             "work_packet_digest" => report["provenance"]["work_packet_digest"],
             "compile_manifest_sha256" => report["provenance"]["compile_manifest_sha256"],
             "workspace_provenance_sha256" => report["provenance"]["workspace_provenance_sha256"],
             "workspace_lifecycle" => "retained_reactivated"
           }

    encoded = Jason.encode!(report)
    refute encoded =~ Base.encode64(authority.token)
    refute encoded =~ "signing_authority"
    refute encoded =~ "private_key"
  end

  test "genuine process-owned authority is closed after verifier error", ctx do
    configure_executor(:inspection_error)

    assert {:error, :workspace_inspection_failed} =
             verify_operator(plan!("default"), request(ctx.agent_id, "default"))

    assert_receive {:operator_candidate_executor, "coding_workspace_inspect", _params, _opts,
                    authority, {:ok, _signed_request}}

    assert {:error, :authority_not_found} =
             Security.sign_with_authority(authority, "after-error")
  end

  test "unconfirmed approval cleanup preserves the original worker error", ctx do
    configure_executor(:inspection_error)
    configure_approval(cleanup_result: :error)

    assert {:error, {:approval_cleanup_unconfirmed, :workspace_inspection_failed}} =
             verify_operator(plan!("default"), request(ctx.agent_id, "default"))

    assert_receive {:operator_candidate_executor, "coding_workspace_inspect", _params, _opts,
                    authority, {:ok, _signed_request}}

    assert_receive {:operator_candidate_approval_cleanup, @task_id, cleanup_opts}
    assert cleanup_opts[:cleanup_reason] == :task_termination

    assert {:error, :authority_not_found} =
             Security.sign_with_authority(authority, "after-unconfirmed-cleanup")
  end

  test "genuine authority is revoked when the code-owned wall-clock deadline expires", ctx do
    configure_executor(:timeout)
    started_at = System.monotonic_time(:millisecond)

    assert {:error, :candidate_verification_timeout} =
             verify_operator(
               plan!("default", 10_000),
               request(ctx.agent_id, "default")
             )

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert elapsed_ms < 15_000

    assert_receive {:operator_candidate_executor, "coding_workspace_inspect", _params, _opts,
                    authority, {:ok, _signed_request}}

    assert {:error, :authority_not_found} =
             Security.sign_with_authority(authority, "after-deadline")

    refute Agent.get(ctx.approval_state, & &1.pending)
  end

  test "genuine authority is revoked when the RPC owner disappears", ctx do
    configure_executor(:timeout)
    plan = plan!("default")
    archive_reviewed_plan!(plan)
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          OperatorCandidateVerifier.verify(
            plan,
            request(ctx.agent_id, "default")
          )

        send(parent, {:operator_candidate_timeout_result, result})
      end)

    assert_receive {:operator_candidate_executor, "coding_workspace_inspect", _params, _opts,
                    authority, {:ok, _signed_request}},
                   10_000

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}

    assert eventually(fn ->
             Security.sign_with_authority(authority, "after-timeout") ==
               {:error, :authority_not_found}
           end)

    assert eventually(fn -> not Agent.get(ctx.approval_state, & &1.pending) end)
    refute_received {:operator_candidate_timeout_result, _result}
  end

  test "security regression: requester death cancels authority and pending approval", ctx do
    configure_executor(:timeout)
    plan = plan!("default")
    archive_reviewed_plan!(plan)
    requester = spawn(fn -> Process.sleep(:infinity) end)
    correlation_id = :crypto.strong_rand_bytes(16)
    parent = self()

    {rpc_pid, rpc_monitor} =
      spawn_monitor(fn ->
        Arbor.Orchestrator.verify_coding_candidate_for_operator_rpc(
          requester,
          parent,
          correlation_id,
          plan,
          request(ctx.agent_id, "default")
        )
      end)

    assert_receive {:operator_candidate_executor, "coding_workspace_inspect", _params, _opts,
                    authority, {:ok, _signed_request}},
                   10_000

    assert Agent.get(ctx.approval_state, & &1.pending)
    Process.exit(requester, :kill)

    assert_receive {:arbor_operator_candidate_verification_rpc_cancelled, ^correlation_id, :ok},
                   10_000

    assert_receive {:operator_candidate_approval_cleanup, @task_id, cleanup_opts}
    assert cleanup_opts[:caller_id] == ctx.agent_id
    assert cleanup_opts[:principal_id] == ctx.agent_id
    assert cleanup_opts[:cleanup_reason] == :task_cancellation
    assert_receive {:operator_candidate_approval_inventory, inventory_opts}
    assert inventory_opts[:principal_scope] == :subject
    refute Agent.get(ctx.approval_state, & &1.pending)

    assert {:error, :authority_not_found} =
             Security.sign_with_authority(authority, "after-requester-death")

    assert_receive {:DOWN, ^rpc_monitor, :process, ^rpc_pid, :normal}
  end

  test "security regression: cancellation budget covers delayed authority close and cleanup",
       ctx do
    configure_executor(:timeout)
    configure_approval(authority_close_delay_ms: 3_600, cleanup_delay_ms: 3_600)
    Application.put_env(:arbor_orchestrator, :security_module, DelayedCloseSecurity)
    plan = plan!("default")
    archive_reviewed_plan!(plan)
    requester = spawn(fn -> Process.sleep(:infinity) end)
    correlation_id = :crypto.strong_rand_bytes(16)
    parent = self()

    {rpc_pid, rpc_monitor} =
      spawn_monitor(fn ->
        Arbor.Orchestrator.verify_coding_candidate_for_operator_rpc(
          requester,
          parent,
          correlation_id,
          plan,
          request(ctx.agent_id, "default")
        )
      end)

    assert_receive {:operator_candidate_executor, "coding_workspace_inspect", _params, _opts,
                    authority, {:ok, _signed_request}},
                   10_000

    started_at = System.monotonic_time(:millisecond)
    Process.exit(requester, :kill)

    assert_receive {:arbor_operator_candidate_verification_rpc_cancelled, ^correlation_id, :ok},
                   15_000

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert elapsed_ms >= 7_000
    assert elapsed_ms < Arbor.Orchestrator.operator_candidate_cancellation_grace_ms()
    refute Agent.get(ctx.approval_state, & &1.pending)

    assert {:error, :authority_not_found} =
             Security.sign_with_authority(authority, "after-delayed-cancellation")

    assert_receive {:DOWN, ^rpc_monitor, :process, ^rpc_pid, :normal}
  end

  test "security regression: subject-scoped cleanup preserves approver-only approval", ctx do
    configure_executor(:timeout)
    Agent.update(ctx.approval_state, &Map.put(&1, :approver_only_pending, true))
    plan = plan!("default")
    archive_reviewed_plan!(plan)
    requester = spawn(fn -> Process.sleep(:infinity) end)
    correlation_id = :crypto.strong_rand_bytes(16)
    parent = self()

    {rpc_pid, rpc_monitor} =
      spawn_monitor(fn ->
        Arbor.Orchestrator.verify_coding_candidate_for_operator_rpc(
          requester,
          parent,
          correlation_id,
          plan,
          request(ctx.agent_id, "default")
        )
      end)

    assert_receive {:operator_candidate_executor, "coding_workspace_inspect", _params, _opts,
                    _authority, {:ok, _signed_request}},
                   10_000

    Process.exit(requester, :kill)

    assert_receive {:arbor_operator_candidate_verification_rpc_cancelled, ^correlation_id, :ok},
                   10_000

    refute Agent.get(ctx.approval_state, & &1.pending)
    assert Agent.get(ctx.approval_state, & &1.approver_only_pending)

    assert_receive {:operator_candidate_approval_inventory, inventory_opts}
    assert inventory_opts[:principal_scope] == :subject
    assert_receive {:DOWN, ^rpc_monitor, :process, ^rpc_pid, :normal}
  end

  test "security regression: hermetic retained provenance invokes lineage reactivation",
       ctx do
    configure_resource(:retained)

    assert {:ok, report} =
             verify_operator(plan!("default"), request(ctx.agent_id, "default"))

    assert_receive {:operator_candidate_workspace_reactivated, @workspace_id, @task_id,
                    principal_id}

    assert principal_id == ctx.agent_id
    assert report["status"] == "passed"
    assert report["provenance"]["workspace_lifecycle"] == "retained_reactivated"
    assert is_binary(report["provenance"]["workspace_provenance_sha256"])
  end

  test "security regression: caller-selected downgraded plan fails closed", ctx do
    reviewed = plan!("cross_app")
    archive_reviewed_plan!(reviewed)
    downgraded = Map.put(reviewed, "validation_profile", "default")

    assert {:error, :coding_plan_provenance_mismatch} =
             OperatorCandidateVerifier.verify(
               downgraded,
               request(ctx.agent_id, "cross_app")
             )

    refute_received {:operator_candidate_executor, _action, _params, _opts, _authority, _active}
  end

  test "security regression: caller-selected work packet digest fails closed", ctx do
    reviewed = plan!("default")
    archive_reviewed_plan!(reviewed)

    packet =
      Map.put(
        reviewed["work_packet"],
        "constraints",
        ["caller-selected reduced constraints"]
      )

    {:ok, digest} = WorkPacket.digest(packet)

    tampered =
      reviewed
      |> Map.put("work_packet", packet)
      |> Map.put("work_packet_digest", digest)

    assert {:error, :coding_plan_provenance_mismatch} =
             OperatorCandidateVerifier.verify(
               tampered,
               request(ctx.agent_id, "default")
             )

    refute_received {:operator_candidate_executor, _action, _params, _opts, _authority, _active}
  end

  test "security regression: workspace identity must exist in persisted resource provenance",
       ctx do
    configure_resource(:retained, %{workspace_id: "workspace_other_candidate"})

    assert {:error, :workspace_provenance_mismatch} =
             verify_operator(plan!("default"), request(ctx.agent_id, "default"))

    refute_received {:operator_candidate_executor, _action, _params, _opts, _authority, _active}
  end

  test "security regression: active workspace cannot replace retained provenance", ctx do
    configure_resource(:active)

    assert {:error, :workspace_provenance_mismatch} =
             verify_operator(plan!("default"), request(ctx.agent_id, "default"))

    refute_received {:operator_candidate_executor, _action, _params, _opts, _authority, _active}
  end

  test "security regression: archived repo must match retained canonical repo", ctx do
    plan = plan!("default")
    wrong_repo = canonical_directory!(Path.join(ctx.logs_root, "wrong-repo"))
    configure_resource(:retained, %{repo_path: wrong_repo})

    assert {:error, :workspace_provenance_mismatch} =
             verify_operator(plan, request(ctx.agent_id, "default"))

    refute_received {:operator_candidate_workspace_reactivated, _, _, _}
    refute_received {:operator_candidate_executor, _, _, _, _, _}
  end

  test "security regression: same task and principal in multiple repos cannot redirect workspace",
       ctx do
    plan = plan!("default")
    wrong_repo = canonical_directory!(Path.join(ctx.logs_root, "wrong-target-repo"))

    configure_resource(:retained, %{
      repo_path: wrong_repo,
      additional_resources: [
        %{
          workspace_id: "workspace_same_lineage_other_repo",
          repo_path: ctx.repo_path,
          worktree_path: canonical_directory!(Path.join(ctx.logs_root, "other-worktree"))
        }
      ]
    })

    assert {:error, :workspace_provenance_mismatch} =
             verify_operator(plan, request(ctx.agent_id, "default"))

    refute_received {:operator_candidate_workspace_reactivated, _, _, _}
    refute_received {:operator_candidate_executor, _, _, _, _, _}
  end

  test "security regression: repository path aliases are rejected", ctx do
    alias_path = Path.join(ctx.logs_root, "repo-alias")
    :ok = File.ln_s(ctx.repo_path, alias_path)
    plan = plan!("default", 900_000, alias_path)

    assert {:error, :workspace_provenance_mismatch} =
             verify_operator(plan, request(ctx.agent_id, "default"))

    refute_received {:operator_candidate_workspace_reactivated, _, _, _}
    refute_received {:operator_candidate_executor, _, _, _, _, _}
  end

  test "security regression: request rejects every caller-supplied execution control", ctx do
    plan = plan!("default")
    base_request = request(ctx.agent_id, "default")

    forbidden = %{
      "action" => "shell_execute",
      "validation_program" => %{},
      "path" => "/tmp/attacker",
      "candidate_tree_oid" => String.duplicate("f", 40),
      "observed_at" => @observed_at,
      "timeout" => 86_400_000,
      "adapter" => "caller",
      "private_key" => "secret",
      "signing_authority" => %{"token" => "forged"}
    }

    for {key, value} <- forbidden do
      assert {:error, :invalid_operator_candidate_request} =
               OperatorCandidateVerifier.verify(plan, Map.put(base_request, key, value))
    end

    refute_received {:operator_candidate_executor, _action, _params, _opts, _authority, _active}
  end

  test "security regression: acquisition failures cannot leak key material in the result", ctx do
    Application.put_env(:arbor_orchestrator, :security_module, LeakySecurity)

    result =
      verify_operator(plan!("default"), request(ctx.agent_id, "default"))

    assert result == {:error, :signing_authority_acquisition_failed}
    refute inspect(result) =~ "must-not-cross-boundary"
    refute_received {:operator_candidate_executor, _action, _params, _opts, _authority, _active}
  end

  test "validation program is reconstructed from the reviewed plan", ctx do
    plan = plan!("cross_app", 45_000)
    program = compiled_program!(plan)

    assert {:ok, _report} =
             verify_operator(plan, request(ctx.agent_id, "cross_app"))

    assert_receive {:operator_candidate_executor, "coding_workspace_inspect", _inspect_params,
                    _inspect_opts, _authority, {:ok, _signed_request}}

    assert_receive {:operator_candidate_executor, action, params, _validation_opts, _authority,
                    {:ok, _signed_request}}

    assert action == program["action"]

    assert Map.take(params, Map.keys(program["static_parameters"])) ==
             program["static_parameters"]
  end

  test "contract_change validator is invoked with owner-bound workspace_id", ctx do
    plan = plan!("contract_change")
    program = compiled_program!(plan)

    assert {:ok, report} =
             verify_operator(plan, request(ctx.agent_id, "contract_change"))

    assert report["status"] == "passed"
    assert report["profile"] == "contract_change"

    assert_receive {:operator_candidate_executor, "coding_workspace_inspect", _inspect_params,
                    _inspect_opts, _authority, {:ok, _signed_request}}

    assert_receive {:operator_candidate_executor, action, params, _validation_opts, _authority,
                    {:ok, _signed_request}}

    assert action == "coding_contract_change_validate"
    assert params["workspace_id"] == @workspace_id

    assert Map.take(params, Map.keys(program["static_parameters"])) ==
             program["static_parameters"]

    refute Map.has_key?(params, "path")
    refute Map.has_key?(params, "review_attestation_id")
  end

  test "contract_change human_required compiled plan remains operator-verifiable", ctx do
    plan = Map.put(plan!("contract_change"), "review_profile", "human_required")

    assert {:ok, report} =
             verify_operator(plan, request(ctx.agent_id, "contract_change"))

    assert report["status"] == "passed"
    assert report["profile"] == "contract_change"
    assert report["provenance"]["review_profile"] == "human_required"

    assert Enum.map(report["diagnostics"], & &1["gate_id"]) ==
             expected_gate_ids("contract_change")
  end

  test "workspace, task, and principal mismatches fail before validation", ctx do
    configure_executor(:normal, workspace_id: "workspace_owned_by_another_task")

    assert {:error, :workspace_inspection_failed} =
             verify_operator(plan!("default"), request(ctx.agent_id, "default"))

    assert_receive {:operator_candidate_executor, "coding_workspace_inspect", _params, _opts,
                    _authority, {:ok, _signed_request}}

    refute_validation_call()

    configure_executor(:task_mismatch, expected_task_id: "task_expected_owner")

    assert {:error, :workspace_inspection_failed} =
             verify_operator(plan!("default"), request(ctx.agent_id, "default"))

    assert_receive {:operator_candidate_executor, "coding_workspace_inspect", _params, _opts,
                    _authority, {:ok, _signed_request}}

    refute_validation_call()

    unknown_agent = "agent_" <> String.duplicate("f", 64)

    assert {:error, :workspace_provenance_mismatch} =
             verify_operator(plan!("default"), request(unknown_agent, "default"))

    refute_received {:operator_candidate_executor, _action, _params, _opts, _authority, _active}
  end

  test "security attestation is required only by the security regression profile", ctx do
    security_plan = plan!("security_regression")
    security_request = request(ctx.agent_id, "security_regression")

    assert {:error, :review_attestation_required} =
             verify_operator(
               security_plan,
               Map.delete(security_request, "review_attestation_id")
             )

    refute_received {:operator_candidate_executor, _action, _params, _opts, _authority, _active}

    assert {:error, :review_attestation_forbidden} =
             verify_operator(
               plan!("default"),
               Map.put(request(ctx.agent_id, "default"), "review_attestation_id", "review_123")
             )

    refute_received {:operator_candidate_executor, _action, _params, _opts, _authority, _active}

    assert {:ok, report} =
             verify_operator(security_plan, security_request)

    assert report["profile"] == "security_regression"
  end

  test "security regression: legacy archived capacity binds a fresh successor without replaying the original",
       ctx do
    {:ok, attestations} = Agent.start_link(fn -> %{} end)
    original = "review_attestation_operator_test"
    seed_claimed_original!(attestations, original, ctx.agent_id)
    configure_resource(:retained, attestations: attestations)

    plan = plan!("security_regression")
    request = request(ctx.agent_id, "security_regression")
    archive_reviewed_plan!(plan)
    write_capacity_terminal!(ctx, original)

    assert {:ok, _report} =
             Arbor.Orchestrator.verify_coding_candidate_for_operator(plan, request)

    assert_receive {:operator_candidate_executor, "coding_workspace_inspect", _inspect_params,
                    _inspect_opts, _inspect_authority, {:ok, _inspect_signed}}

    assert_receive {:operator_candidate_executor, "coding_security_regression_validate", params,
                    _opts, _authority, {:ok, _signed}}

    bound = params["review_attestation_id"] || params[:review_attestation_id]
    assert is_binary(bound)
    assert String.starts_with?(bound, "review_attestation_")
    refute bound == original
  end

  test "security regression: non-capacity and mismatched archives cannot reclaim the original",
       ctx do
    {:ok, attestations} = Agent.start_link(fn -> %{} end)
    original = "review_attestation_operator_test"
    seed_claimed_original!(attestations, original, ctx.agent_id)
    configure_resource(:retained, attestations: attestations)

    plan = plan!("security_regression")
    request = request(ctx.agent_id, "security_regression")
    archive_reviewed_plan!(plan)
    write_terminal_status!(ctx, original, "passed")

    assert {:error, :attestation_already_claimed} =
             Arbor.Orchestrator.verify_coding_candidate_for_operator(plan, request)

    refute_received {:operator_candidate_executor, "coding_security_regression_validate", _, _, _,
                     _}

    assert Agent.get(attestations, & &1[original].successor_id) == nil

    write_terminal_status!(ctx, original, "validation_failed")

    assert {:error, :attestation_already_claimed} =
             Arbor.Orchestrator.verify_coding_candidate_for_operator(plan, request)

    archive_reviewed_plan!(plan)
    write_capacity_terminal!(ctx, original, task_id: "task_other")

    assert {:error, :invalid_capacity_retry_proof} =
             Arbor.Orchestrator.verify_coding_candidate_for_operator(plan, request)

    write_capacity_terminal!(ctx, original, candidate_workspace_id: "workspace_other")

    assert {:error, :invalid_capacity_retry_proof} =
             Arbor.Orchestrator.verify_coding_candidate_for_operator(plan, request)

    assert Agent.get(attestations, & &1[original].successor_id) == nil
  end

  test "security regression: admission denial emits no reactivation and a later valid capacity proof retries",
       ctx do
    {:ok, attestations} = Agent.start_link(fn -> %{} end)
    original = "review_attestation_operator_test"
    seed_claimed_original!(attestations, original, ctx.agent_id)
    configure_resource(:retained, attestations: attestations)

    plan = plan!("security_regression")
    request = request(ctx.agent_id, "security_regression")
    archive_reviewed_plan!(plan)
    write_terminal_status!(ctx, original, "passed")

    assert {:error, :attestation_already_claimed} =
             Arbor.Orchestrator.verify_coding_candidate_for_operator(plan, request)

    refute_received {:operator_candidate_workspace_reactivated, _, _, _}

    refute_received {:operator_candidate_executor, "coding_security_regression_validate", _, _, _,
                     _}

    write_capacity_terminal!(ctx, original)

    assert {:ok, _report} =
             Arbor.Orchestrator.verify_coding_candidate_for_operator(plan, request)

    assert_receive {:operator_candidate_workspace_reactivated, @workspace_id, @task_id,
                    principal_id}

    assert principal_id == ctx.agent_id

    assert_receive {:operator_candidate_executor, "coding_workspace_inspect", _, _, _, _}

    assert_receive {:operator_candidate_executor, "coding_security_regression_validate", params,
                    _opts, _authority, {:ok, _signed}}

    bound = params["review_attestation_id"] || params[:review_attestation_id]
    assert is_binary(bound)
    assert String.starts_with?(bound, "review_attestation_")
    refute bound == original
  end

  test "security regression: two consecutive capacity retries walk from the original id", ctx do
    {:ok, attestations} = Agent.start_link(fn -> %{} end)
    original = "review_attestation_operator_test"
    seed_claimed_original!(attestations, original, ctx.agent_id)
    configure_resource(:retained, attestations: attestations)

    plan = plan!("security_regression")
    request = request(ctx.agent_id, "security_regression")
    archive_reviewed_plan!(plan)
    write_capacity_terminal!(ctx, original)

    assert {:ok, _first} =
             Arbor.Orchestrator.verify_coding_candidate_for_operator(plan, request)

    assert_receive {:operator_candidate_executor, "coding_workspace_inspect", _, _, _, _}

    assert_receive {:operator_candidate_executor, "coding_security_regression_validate",
                    first_params, _opts, _authority, {:ok, _signed}}

    s1 = first_params["review_attestation_id"] || first_params[:review_attestation_id]
    refute s1 == original

    Agent.update(attestations, fn state ->
      Map.update!(state, s1, fn record ->
        %{record | status: :claimed, capacity_evidence: %{"reason" => "validation_capacity_exceeded"}}
      end)
    end)

    assert {:ok, _second} =
             Arbor.Orchestrator.verify_coding_candidate_for_operator(plan, request)

    assert_receive {:operator_candidate_executor, "coding_workspace_inspect", _, _, _, _}

    assert_receive {:operator_candidate_executor, "coding_security_regression_validate",
                    second_params, _opts2, _authority2, {:ok, _signed2}}

    s2 = second_params["review_attestation_id"] || second_params[:review_attestation_id]
    refute s2 == original
    refute s2 == s1

    Agent.update(attestations, fn state ->
      Map.update!(state, s2, fn record ->
        %{record | status: :claimed, capacity_evidence: nil}
      end)
    end)

    assert {:error, :capacity_retry_denied} =
             Arbor.Orchestrator.verify_coding_candidate_for_operator(plan, request)
  end

  test "security regression: unexpected terminal-evidence reader results fail closed as invalid proof",
       ctx do
    previous_store = Application.get_env(:arbor_orchestrator, :coding_plan_artifact_store)

    Application.put_env(
      :arbor_orchestrator,
      :coding_plan_artifact_store,
      TestTerminalEvidenceStore
    )

    on_exit(fn ->
      restore_env(:arbor_orchestrator, :coding_plan_artifact_store, previous_store)
      Application.delete_env(:arbor_orchestrator, :operator_candidate_verifier_test_terminal_read)
    end)

    plan = plan!("security_regression")
    request = request(ctx.agent_id, "security_regression")
    archive_reviewed_plan!(plan)
    configure_resource(:retained)

    for mode <- [:unexpected_ok, :unexpected_error, :other, :raise, :exit] do
      Application.put_env(
        :arbor_orchestrator,
        :operator_candidate_verifier_test_terminal_read,
        mode
      )

      result = Arbor.Orchestrator.verify_coding_candidate_for_operator(plan, request)
      assert result == {:error, :invalid_capacity_retry_proof}
      refute inspect(result) =~ "stub-terminal-reader-secret"
    end
  end

  test "security regression: admit_bound_attestation redacts nested facade errors and never leaks secrets",
       ctx do
    plan = plan!("security_regression")
    request = request(ctx.agent_id, "security_regression")
    archive_reviewed_plan!(plan)

    configure_resource(:retained, admit_error: %{token: "admit-bound-secret-token"})

    secret_map_result =
      Arbor.Orchestrator.verify_coding_candidate_for_operator(plan, request)

    assert secret_map_result == {:error, :capacity_retry_denied}
    refute inspect(secret_map_result) =~ "admit-bound-secret-token"

    configure_resource(:retained,
      admit_error: {:git, %{stderr: "admit-bound-secret-token"}}
    )

    git_result = Arbor.Orchestrator.verify_coding_candidate_for_operator(plan, request)
    assert git_result == {:error, :capacity_retry_denied}
    refute inspect(git_result) =~ "admit-bound-secret-token"
  end

  test "security regression: nested validator rejections stay allowlisted and secrets do not leak",
       ctx do
    plan = plan!("security_regression")
    request = request(ctx.agent_id, "security_regression")
    configure_executor(:validator_attestation_claimed)

    assert {:error, {:validator_rejected, :attestation_already_claimed}} =
             verify_operator(plan, request)

    configure_executor(:validator_secret_map)

    result = verify_operator(plan, request)
    assert result == {:error, :validator_execution_failed}
    refute inspect(result) =~ "must-not-leak"
  end

  test "security regression: registry restart without in-memory predecessor fail-closes retry",
       ctx do
    {:ok, attestations} = Agent.start_link(fn -> %{} end)
    configure_resource(:retained, attestations: attestations)

    plan = plan!("security_regression")
    request = request(ctx.agent_id, "security_regression")
    archive_reviewed_plan!(plan)
    write_capacity_terminal!(ctx, request["review_attestation_id"])

    assert {:error, :not_found} =
             Arbor.Orchestrator.verify_coding_candidate_for_operator(plan, request)

    refute_received {:operator_candidate_executor, "coding_security_regression_validate", _, _, _,
                     _}
  end

  defp configure_executor(mode, overrides \\ []) do
    config =
      %{
        mode: mode,
        observer: self(),
        workspace_id: @workspace_id,
        expected_task_id: @task_id,
        worktree_path:
          :arbor_orchestrator
          |> Application.fetch_env!(:operator_candidate_verifier_test_resource)
          |> Map.fetch!(:worktree_path)
      }
      |> Map.merge(Map.new(overrides))

    Application.put_env(
      :arbor_orchestrator,
      :operator_candidate_verifier_test_executor,
      config
    )
  end

  defp configure_resource(state, overrides \\ %{}) do
    config =
      :arbor_orchestrator
      |> Application.fetch_env!(:operator_candidate_verifier_test_resource)
      |> Map.merge(%{observer: self(), state: state})
      |> Map.merge(Map.new(overrides))

    Application.put_env(
      :arbor_orchestrator,
      :operator_candidate_verifier_test_resource,
      config
    )
  end

  defp configure_approval(overrides) do
    config =
      :arbor_orchestrator
      |> Application.fetch_env!(:operator_candidate_verifier_test_approval)
      |> Map.merge(Map.new(overrides))

    Application.put_env(
      :arbor_orchestrator,
      :operator_candidate_verifier_test_approval,
      config
    )
  end

  defp plan!(profile, wall_clock_ms \\ 900_000, repo_root \\ nil) do
    checkpoint_policy =
      if Plan.design_checkpoint_required?("default", profile),
        do: "design_required",
        else: "direct"

    work_packet = %{
      "version" => 1,
      "success_criteria" => ["candidate verification passes"],
      "non_goals" => ["expand operator authority"],
      "constraints" => ["use retained task provenance"],
      "architecture_refs" => [
        "apps/arbor_orchestrator/lib/arbor/orchestrator/coding_plan/operator_candidate_verifier.ex"
      ],
      "required_evidence" => ["normalized verification report"],
      "checkpoint_policy" => checkpoint_policy
    }

    {:ok, work_packet_digest} = WorkPacket.digest(work_packet)

    attrs = %{
      "version" => 2,
      "task" => "Verify a retained coding candidate",
      "repo_root" => repo_root || configured_repo_path(),
      "worker" => %{"provider" => "grok"},
      "validation_profile" => profile,
      "budgets" => %{"wall_clock_ms" => wall_clock_ms},
      "work_packet" => work_packet,
      "work_packet_digest" => work_packet_digest
    }

    attrs =
      if profile == "security_regression" do
        Map.put(attrs, "requested_paths", [
          "apps/arbor_orchestrator/test/operator_candidate_security_regression_test.exs"
        ])
      else
        attrs
      end

    {:ok, plan} = Plan.new(attrs)
    Plan.to_map(plan)
  end

  defp configured_repo_path do
    :arbor_orchestrator
    |> Application.fetch_env!(:operator_candidate_verifier_test_resource)
    |> Map.fetch!(:repo_path)
  end

  defp canonical_directory!(path) do
    File.mkdir_p!(path)
    {:ok, canonical} = SafePath.resolve_real(path)
    canonical
  end

  defp verify_operator(plan, request) do
    archive_reviewed_plan!(plan)
    Arbor.Orchestrator.verify_coding_candidate_for_operator(plan, request)
  end

  defp seed_claimed_original!(agent, original, principal_id) do
    Agent.update(agent, fn _ ->
      %{
        original => %{
          status: :claimed,
          predecessor_id: nil,
          successor_id: nil,
          retry_index: 0,
          origin: :council_issued,
          capacity_evidence: nil,
          task_id: @task_id,
          principal_id: principal_id,
          workspace_id: @workspace_id
        }
      }
    end)
  end

  defp write_capacity_terminal!(_ctx, original, overrides \\ []) do
    task_id = Keyword.get(overrides, :task_id, @task_id)
    root = prepare_terminal_root!()

    result =
      capacity_terminal_result(root)
      |> maybe_put_candidate_override(Keyword.get(overrides, :candidate_workspace_id))

    assert {:ok, _descriptor} =
             ArtifactStore.archive_terminal_evidence(root, task_id, result, [])

    original
  end

  defp write_terminal_status!(_ctx, original, status) do
    root = prepare_terminal_root!()
    _ = File.rm(Path.join(root, "coding-terminal-evidence.json"))

    {terminal_status, outcome, validation} =
      case status do
        "validation_failed" ->
          {"validation_failed",
           %{
             "version" => 1,
             "disposition" => "failed",
             "code" => "validation_failed",
             "phase" => "validation",
             "origin" => "validator",
             "retry" => "same_session"
           }, [%{"command" => "mix test", "passed" => false}]}

        _other ->
          {"change_committed",
           %{
             "version" => 1,
             "disposition" => "succeeded",
             "code" => "change_committed",
             "phase" => "commit",
             "origin" => "arbor",
             "retry" => "none"
           }, [%{"command" => "mix test", "passed" => true}]}
      end

    result = %{
      "status" => terminal_status,
      "canonical_status" => terminal_status,
      "outcome" => outcome,
      "validation" => validation,
      "review" => %{},
      "artifacts" => compiled_workflow_artifacts(root)
    }

    assert {:ok, _descriptor} =
             ArtifactStore.archive_terminal_evidence(root, @task_id, result, [])

    original
  end

  defp prepare_terminal_root! do
    root = task_artifact_root(@task_id)
    File.mkdir_p!(root)
    {:ok, canonical} = SafePath.resolve_real(root)
    canonical
  end

  defp capacity_terminal_result(root) do
    digest = String.duplicate("d", 64)
    source_digest = String.duplicate("e", 64)
    path = "apps/arbor_orchestrator/test/operator_candidate_security_regression_test.exs"

    %{
      "status" => "validation_capacity_exceeded",
      "canonical_status" => "validation_capacity_exceeded",
      "outcome" => %{
        "version" => 1,
        "disposition" => "requires_input",
        "code" => "validation_capacity_exceeded",
        "phase" => "validation",
        "origin" => "validator",
        "retry" => "after_external_change"
      },
      "validation" => [
        %{
          "passed" => false,
          "reason" => "validation_capacity_exceeded",
          "evidence_type" => "reviewed_regression_evidence",
          "candidate_fingerprint" => digest,
          "review_attestation_digest" => digest,
          "council_decision_digest" => source_digest,
          "attested_base_commit" => String.duplicate("c", 40),
          "attested_candidate_commit" => String.duplicate("b", 40),
          "attested_candidate_tree_oid" => @candidate_tree_oid,
          "attested_diff_sha256" => digest,
          "attested_selected_tests" => [
            %{"path" => path, "blob_sha256" => source_digest}
          ],
          "candidate" => %{
            "completed" => false,
            "status" => "stage_timeout",
            "exit_code" => nil,
            "timed_out" => true
          },
          "base" => %{
            "completed" => false,
            "status" => "not_run",
            "exit_code" => nil,
            "timed_out" => false
          },
          "termination" => %{
            "timed_out" => true,
            "killed" => false,
            "output_limit_exceeded" => false,
            "cancelled" => false
          }
        }
      ],
      "review" => %{},
      "artifacts" => compiled_workflow_artifacts(root)
    }
  end

  defp compiled_workflow_artifacts(root) do
    %{
      "coding_plan_path" => Path.join(root, "coding-plan.json"),
      "coding_pipeline_path" => Path.join(root, "coding-pipeline.dot"),
      "compile_manifest_path" => Path.join(root, "coding-compile-manifest.json"),
      "graph_hash" => String.duplicate("a", 64),
      "compiler_version" => "coding-plan-1"
    }
  end

  defp maybe_put_candidate_override(result, nil), do: result

  defp maybe_put_candidate_override(result, workspace_id) do
    repo_path = Path.dirname(result["artifacts"]["coding_plan_path"])

    result
    |> Map.put("workspace_id", workspace_id)
    |> Map.put("repo_path", repo_path)
    |> Map.put("branch", "test/operator-candidate")
    |> Map.put("base_commit", String.duplicate("c", 40))
    |> Map.put("commit_hash", String.duplicate("b", 40))
    |> Map.put("branch_provenance", "created")
    |> Map.put("evidence_ref", "refs/arbor/evidence/operator-candidate")
  end

  defp archive_reviewed_plan!(plan) do
    {:ok, compilation} = Arbor.Orchestrator.compile_coding_plan(plan)
    root = task_artifact_root(@task_id)
    File.rm_rf!(root)
    File.mkdir_p!(root)

    assert {:ok, _descriptor} =
             ArtifactStore.archive(
               root,
               compilation["plan_map"],
               compilation["dot_source"],
               compilation["manifest"]
             )

    :ok
  end

  defp task_artifact_root(task_id) do
    digest =
      task_id
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    Path.join(Config.coding_pipeline_logs_root(), "task-" <> digest)
  end

  defp compiled_program!(plan) do
    {:ok, compilation} = Arbor.Orchestrator.compile_coding_plan(plan)
    get_in(compilation, ["initial_values", "coding_plan_validation_program"])
  end

  defp request(agent_id, profile) do
    %{
      "agent_id" => agent_id,
      "task_id" => @task_id,
      "workspace_id" => @workspace_id
    }
    |> maybe_put(
      "review_attestation_id",
      if(profile == "security_regression", do: "review_attestation_operator_test")
    )
  end

  defp candidate(program, profile) do
    %{
      "workspace_id" => @workspace_id,
      "validation_program" => program
    }
    |> maybe_put(
      "review_attestation_id",
      if(profile == "security_regression", do: "review_attestation_operator_test")
    )
  end

  defp expected_gate_ids("default"), do: ["coding.validation.default.compile"]

  defp expected_gate_ids("cross_app") do
    [
      "coding.validation.cross_app.compile",
      "coding.validation.cross_app.xref",
      "coding.validation.cross_app.test_compile",
      "coding.validation.cross_app.tests"
    ]
  end

  defp expected_gate_ids("security_regression") do
    [
      "coding.validation.security_regression.attestation",
      "coding.validation.security_regression.candidate",
      "coding.validation.security_regression.base"
    ]
  end

  defp expected_gate_ids("contract_change") do
    [
      "coding.validation.contract_change.preflight",
      "coding.validation.contract_change.tests"
    ]
  end

  defp open_authority(agent_id, private_key, purpose) do
    with {:ok, proof} <-
           Security.build_signing_authority_acquisition_proof(
             agent_id,
             private_key,
             purpose: purpose,
             owner: self()
           ) do
      Security.open_signing_authority(proof)
    end
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, _attempts) when not is_function(fun, 0), do: false
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp refute_validation_call do
    refute_receive {:operator_candidate_executor, "mix_compile", _params, _opts, _authority,
                    _active}
  end

  defp ensure_authority_stack! do
    {:ok, _started} = Application.ensure_all_started(:arbor_security)
    ensure_buffered_store!(:arbor_security_identities, "identities")
    ensure_buffered_store!(:arbor_security_signing_keys, "signing_keys")
    ensure_buffered_store!(:arbor_security_capabilities, "capabilities")
    ensure_child!(Arbor.Security.Identity.Registry, [])
    ensure_child!(Arbor.Security.Identity.NonceCache, [])
    ensure_child!(Arbor.Security.SystemAuthority, [])
    ensure_authority_pair!()
  end

  defp ensure_authority_pair! do
    case {Process.whereis(Arbor.Security.SigningAuthorityStateOwner),
          Process.whereis(SigningAuthorityBroker)} do
      {nil, nil} ->
        token = make_ref()
        ensure_child!(Arbor.Security.SigningAuthorityStateOwner, broker_token: token)
        ensure_child!(SigningAuthorityBroker, state_owner_token: token)

      {owner, nil} when is_pid(owner) ->
        case Supervisor.restart_child(Arbor.Security.Supervisor, SigningAuthorityBroker) do
          {:ok, _pid} -> :ok
          {:ok, _pid, _info} -> :ok
          other -> flunk("failed to restart SigningAuthorityBroker: #{inspect(other)}")
        end

      {owner, broker} when is_pid(owner) and is_pid(broker) ->
        :ok

      partial ->
        flunk("partial signing authority stack: #{inspect(partial)}")
    end
  end

  defp ensure_buffered_store!(name, collection) do
    if is_nil(Process.whereis(name)) do
      child =
        Supervisor.child_spec(
          {Arbor.Persistence.BufferedStore,
           name: name, backend: nil, write_mode: :sync, collection: collection},
          id: name
        )

      case Supervisor.start_child(Arbor.Security.Supervisor, child) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, :already_present} -> :ok
        {:error, {:already_present, _child}} -> :ok
      end
    end
  end

  defp ensure_child!(module, args) do
    if is_nil(Process.whereis(module)) do
      case Supervisor.start_child(Arbor.Security.Supervisor, {module, args}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, :already_present} -> :ok
        {:error, {:already_present, _child}} -> :ok
      end
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
