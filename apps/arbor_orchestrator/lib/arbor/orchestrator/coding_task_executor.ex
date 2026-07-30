defmodule Arbor.Orchestrator.CodingTaskExecutor do
  @moduledoc """
  `Arbor.Contracts.Agent.TaskExecutor` for the packaged coding-change pipeline.

  Accepts canonical JSON task maps with `kind: "coding_change"` in either the
  legacy flat shape or the versioned `Coding.Plan` shape. A reviewed compiler
  turns the normalized plan and trusted packaged template into immutable DOT;
  the exact plan, graph, and compile manifest are archived before execution.
  Engine opts come only from that compilation, allowlisted context fields, and
  trusted `run/3` identity — never from task-supplied authority or graph data.

  Authorization is mandatory (`authorization: true`) with a reload-stable
  `SigningAuthority` acquired from the target agent's signing key via the
  public Security facade. Missing identity/key/runtime graph fails closed (no
  system/unsigned fallback).

  This production executor always requires a live security runtime
  (`Config.security_available?/0`) before invoking any runner, regardless of
  the global standalone `security_required?` escape hatch. Repository and
  worktree paths must resolve inside explicitly configured workspace roots.
  These roots constrain task input only; they do not grant filesystem
  capabilities or replace authorization.

  ## JSON boundary

  Production TaskStore already canonicalizes. This module therefore accepts
  only non-struct, string-keyed JSON maps at `run/3`, `task_status/2`, and
  `cancel_task/2`, and `steer_task/3`. Atom keys, keywords, structs, PIDs,
  functions, and other non-JSON values are rejected (not stringified). Unknown
  context keys are rejected. Optional context fields are type-checked:
  `task_id` / `caller_id` nonblank strings, `timeout` a positive integer when
  present, `metadata` a JSON object when present. Each task receives an
  isolated, path-safe Engine logs directory. A supplied `timeout` is forwarded
  to Engine handlers and bounds the complete runner invocation. Immediately
  before that runner timeout starts, the executor seeds the owner-generated
  absolute Unix-ms deadline as `session.run_deadline_unix_ms` in ordinary
  JSON-clean Engine initial context so checkpoints retain the same authority
  across resume.

  Steering never accepts a worker handle or principal override. It binds the
  persisted control's exact task id to the execution context, embeds the user
  correction as bounded JSON data in a same-session instruction, and resolves
  the active session only through the public managed ACP task/principal facade.
  The same callback is used for initial delivery, confirmation, and replay.
  The `control_id` and steering payload (`message`, `sender_id`,
  `target_stage`, `sequence`) are stable across all calls for the same
  control; only bookkeeping fields (`status`, `delivery_mode`, `delivered_at`,
  `error`) may differ between calls. The evidence atoms `:not_delivered`,
  `:delivery_unknown`, and `:cancelled` are preserved distinctly for
  TaskStore's delivery lifecycle (retry vs. replay vs. terminalize) and are
  never persisted as control statuses. `:not_delivered` is retryable/replayable;
  `:delivery_unknown` and `:cancelled` terminalize immediately as
  `"delivery_unconfirmed"` regardless of phase.
  """

  @behaviour Arbor.Contracts.Agent.TaskExecutor

  alias Arbor.Common.SafePath

  alias Arbor.Contracts.Coding.{
    AdmissionFailure,
    BranchLifecycleDescriptor,
    Diagnostic,
    Plan,
    ReadinessReport,
    TaskEvidenceDescriptor,
    TaskOutcome,
    TranscriptDescriptor,
    VerificationReport,
    WorkPacket,
    WorkspaceReleaseDescriptor
  }

  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Orchestrator.Config

  alias Arbor.Orchestrator.CodingPlan.{
    ActionCatalog,
    ArtifactStore,
    BudgetPolicy,
    CandidateVerificationCore,
    Compilation,
    ExecutionManifest,
    Normalizer,
    OutcomeMapper,
    Profiles,
    Readiness,
    SemanticPreflight,
    TaskTerminalArchiveCore,
    ValidationCapacityTerminal,
    ValidationProgram
  }

  alias Arbor.Orchestrator.Dot.Parser
  alias Arbor.Orchestrator.IR.Compiler, as: IRCompiler
  alias Arbor.Orchestrator.RunLifecycle.Adapter, as: RunLifecycleAdapter

  @allowed_context_keys MapSet.new(~w(task_id timeout caller_id metadata))

  @allowed_control_keys MapSet.new(~w(
    control_id
    task_id
    sequence
    status
    sender_id
    message
    queued_at
    delivered_at
    target_stage
    delivery_mode
    error
  ))

  @forbidden_control_keys MapSet.new(~w(
    worker_session_id
    session_pid
    worker_pid
    owner_pid
    principal_id
    agent_id
    task_principal_id
    authorization
    signer
    capabilities
    identity
    private_key
    signing_key
  ))

  @max_control_id_bytes 256
  @max_control_task_id_bytes 512
  @max_control_message_bytes 4_000
  @max_target_stage_bytes 200
  @max_follow_up_instruction_bytes 16_384
  @max_metric_completed_nodes 500
  @max_metric_node_durations 500
  @max_metric_node_id_bytes 256
  @max_metric_usage_entries 32
  @max_metric_usage_list_items 32
  @max_metric_usage_depth 3
  @max_metric_usage_key_bytes 128
  @max_metric_usage_string_bytes 1_024
  @max_metric_usage_encoded_bytes 16_384
  @max_validation_failure_reason_bytes 512
  @max_pipeline_failure_reason_bytes 512
  @max_workspace_recovery_items 16
  @max_workspace_recovery_string_bytes 512
  @workspace_recovery_resource_types ~w(retained_workspace_record live_workspace_lease)

  @pipeline_error_failure_nodes %{
    "worker_recovery_send_failed" => "retry_recovered_send"
  }

  @generic_pipeline_failure_nodes ~w(
    acquire_workspace
    open_worker
    capture_pre_turn_workspace
    capture_pre_turn_recovery
    inspect_workspace
    capture_validation_workspace
    hoist_validation_candidate_tree_oid
    hoist_validation_observed_at
    commit_change
  )

  @terminal_control_errors MapSet.new([
                             :unsupported,
                             :not_supported,
                             :task_control_unsupported,
                             :nonrecoverable,
                             :non_recoverable,
                             :ambiguous_task_control_session,
                             :invalid_task_control,
                             :invalid_control_id,
                             :invalid_control_message,
                             :invalid_task_id,
                             :blank_task_control
                           ])

  @forbidden_context_keys MapSet.new(~w(
    approval_timeout_ms
    authorization
    signer
    agent_id
    engine
    engine_module
    action_executor
    actions_executor
    graph
    graph_path
    capabilities
    identity
    authorizer
    private_key
    signing_key
    identity_private_key
  ))

  @artifact_descriptor_keys MapSet.new(~w(
    coding_plan_path
    coding_pipeline_path
    compile_manifest_path
    graph_hash
    compiler_version
  ))

  @artifact_path_keys ~w(coding_plan_path coding_pipeline_path compile_manifest_path)

  @finalize_result_keys MapSet.new(~w(
    status
    canonical_status
    branch
    branch_provenance
    base_commit
    commit
    commit_hash
    repo_path
    worktree_path
    diff
    files
    validation
    verification_report
    review
    review_recommendation
    tier_decision
    human_required
    security_veto
    blast_radius
    pr_url
    workspace_id
    worker_session_id
    worker_provider_session_id
    response_text
    error
    approval_request_id
    approval_note
    acp_agent
    worker_provider
    outcome
    metrics
    workspace_release_status
    workspace_expires_at
    evidence_ref
    published_commit
    artifacts
    branch_lifecycle
  ))

  @finalize_artifact_optional_keys MapSet.new(
                                     ~w(acp_transcript workspace_release branch_lifecycle)
                                   )
  @max_finalize_controls 100
  @max_finalize_task_id_bytes 512

  @adoptable_statuses MapSet.new(~w(change_committed human_review_required pr_created))
  @adoption_request_keys MapSet.new(~w(destination_ref))
  @adoption_candidate_keys MapSet.new(~w(
    base_commit
    branch
    branch_provenance
    candidate_commit
    evidence_ref
    repo_path
    task_id
    workspace_id
  ))
  @max_destination_ref_bytes 256

  @type json_map :: Arbor.Contracts.Agent.TaskExecutor.json_map()

  @doc """
  Run the coding-change pipeline for `agent_id`.

  `task` must be a JSON-clean string-keyed map with `kind: "coding_change"` and
  either legacy coding fields or a versioned `plan` object. `context` must
  include a nonblank `task_id`; optional `timeout` / `caller_id` / `metadata`
  are accepted as data only (not as control authority).
  """
  @impl true
  @spec run(String.t(), term(), map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def run(agent_id, task, context) when is_binary(agent_id) do
    started_at = System.monotonic_time(:millisecond)

    with :ok <- validate_agent_id(agent_id),
         {:ok, exec_ctx} <- validate_context(context),
         {:ok, canonical_plan, compilation, readiness_report} <-
           admit_coding_plan(task, agent_id),
         {:ok, security} <- security_facade(),
         {:ok, authority} <- acquire_signing_authority(security, agent_id) do
      try do
        with {:ok, logs_root} <- prepare_task_logs_root(exec_ctx.task_id),
             {:ok, artifacts} <-
               archive_compilation(logs_root, canonical_plan, compilation)
               |> map_post_readiness_immutable_failure(readiness_report, :archive),
             {:ok, {pinned_action_bindings, pinned_handler_bindings}} <-
               verify_execution_boundary(
                 Map.fetch!(artifacts, "coding_pipeline_path"),
                 canonical_plan,
                 compilation
               )
               |> map_post_readiness_immutable_failure(
                 readiness_report,
                 :execution_boundary
               ),
             {:ok, opts} <-
               build_engine_opts(
                 agent_id,
                 canonical_plan,
                 compilation,
                 exec_ctx,
                 authority,
                 logs_root,
                 pinned_action_bindings,
                 pinned_handler_bindings
               ),
             :ok <- validate_authority_signing(security, authority),
             # Startup URI registration is a snapshot; reconcile hot-loaded actions.
             :ok <- reconcile_action_uri_prefixes(),
             {:ok, engine_result} <-
               invoke_runner(Map.fetch!(artifacts, "coding_pipeline_path"), opts),
             {:ok, result} <-
               adapt_result(
                 engine_result,
                 started_at,
                 Map.fetch!(canonical_plan.worker, "provider"),
                 Map.get(canonical_plan.worker, "model")
               ),
             release_artifacts = attach_workspace_release_artifact(artifacts, result),
             {:ok, public_artifacts} <-
               attach_transcript_artifact(
                 release_artifacts,
                 logs_root,
                 exec_ctx.task_id,
                 engine_result
               ) do
          {:ok, Map.put(result, "artifacts", public_artifacts)}
        end
      after
        # The broker monitors this run process, but normal terminal outcomes
        # must release the authority before returning to TaskStore.
        _ = close_signing_authority(security, authority)
      end
    end
  end

  def run(_agent_id, _task, _context), do: {:error, :invalid_agent_id}

  @doc """
  Project JSON-clean progress for TaskStore from PipelineStatus.

  Returns only `current_step` and `waiting_on` (string or nil). Never returns
  PIDs or RunState structs.
  """
  @impl true
  @spec task_status(String.t(), map() | keyword()) ::
          {:ok, json_map()} | {:error, term()}
  def task_status(_agent_id, context) do
    with {:ok, exec_ctx} <- validate_context(context),
         task_id <- exec_ctx.task_id do
      case Config.pipeline_status_module().get(task_id) do
        nil ->
          {:error, :not_found}

        entry when is_map(entry) ->
          {:ok, progress_from_entry(entry)}

        _other ->
          {:error, :invalid_pipeline_status}
      end
    end
  rescue
    e -> {:error, {:pipeline_status_error, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:pipeline_status_exit, reason}}
  end

  @doc """
  Cooperative cancel bookkeeping: mark the pipeline run abandoned.

  Idempotent and bounded. TaskStore still owns hard process termination and
  monitored resource cleanup.
  """
  @impl true
  @spec cancel_task(String.t(), map() | keyword()) :: :ok | {:error, term()}
  def cancel_task(_agent_id, context) do
    with {:ok, exec_ctx} <- validate_context(context),
         task_id <- exec_ctx.task_id do
      _ = Config.pipeline_status_module().mark_abandoned(task_id)
      :ok
    end
  rescue
    e -> {:error, {:pipeline_cancel_error, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:pipeline_cancel_exit, reason}}
  end

  @doc """
  Deliver a persisted TaskStore control to the active managed ACP worker.

  The exact control/task ids are retained for managed-session dedupe. Delivery
  is resolved only by the context-bound task id and callback `agent_id`; worker
  handles, PIDs, and caller-provided principal overrides are rejected.

  TaskStore calls this same callback for initial delivery, confirmation, and
  replay. The `control_id` and steering payload (`message`, `sender_id`,
  `target_stage`, `sequence`) are stable across all calls for the same
  control; only bookkeeping fields (`status`, `delivery_mode`, `delivered_at`,
  `error`) may differ between calls.

  ## Return values and delivery semantics

  - `{:ok, mode}` — delivered immediately. TaskStore sets `delivered_at`.
  - `{:ok, :queued, mode}` — accepted only. TaskStore confirms by calling
    `steer_task/3` again with the same control.
  - `{:error, :not_delivered}` — positive nondelivery. During confirmation,
    TaskStore clears accepted ownership and triggers a bounded same-ID replay.
    During initial delivery or replay delivery it is retryable (bounded by the
    initial delivery budget).
  - `{:error, :delivery_unknown}` — ambiguous. Unsafe to retry or replay.
    TaskStore terminalizes the control as `"delivery_unconfirmed"` regardless
    of phase (initial delivery, confirmation, or replay).
  - `{:error, :cancelled}` — explicit cancellation. Same terminalization as
    `:delivery_unknown` with a distinct bounded error.
  - `{:error, :unsupported}` — terminal. This executor cannot steer.
  - `{:error, term()}` — other operational errors. Retained by TaskStore as
    deferred for bounded retry.

  Queued controls are durably accepted same-session follow-ups. Deferred or
  operational results remain retryable so TaskStore retains the same control
  id, while explicit unsupported/ambiguous outcomes are terminal.
  """
  @impl true
  @spec steer_task(String.t(), term(), map() | keyword()) ::
          Arbor.Contracts.Agent.TaskExecutor.steering_result()
  def steer_task(agent_id, control, context) do
    with :ok <- validate_steering_agent_id(agent_id),
         {:ok, control_data} <- validate_steering_control(control),
         {:ok, exec_ctx} <- validate_context(context),
         :ok <- ensure_same_task(control_data.task_id, exec_ctx.task_id),
         {:ok, managed_control} <- build_managed_control(control_data) do
      deliver_managed_control(control_data.task_id, agent_id, managed_control)
    end
  end

  @doc "Persist terminal coding evidence and attach its verified descriptor."
  @impl true
  @spec finalize_task(String.t(), map(), list(), map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def finalize_task(agent_id, result, controls, context) do
    with :ok <- validate_agent_id(agent_id),
         {:ok, exec_ctx} <- validate_context(context),
         :ok <- validate_finalize_task_id(exec_ctx.task_id),
         {:ok, result} <- normalize_finalize_result(result),
         :ok <- validate_finalize_controls(controls),
         {:ok, logs_root} <- prepare_task_logs_root(exec_ctx.task_id),
         :ok <- validate_finalize_artifact_files(result, logs_root),
         {:ok, descriptor} <-
           archive_terminal_evidence(logs_root, exec_ctx.task_id, result, controls),
         {:ok, descriptor} <-
           validate_terminal_evidence_descriptor(descriptor, logs_root, exec_ctx.task_id) do
      artifacts = Map.fetch!(result, "artifacts")
      {:ok, Map.put(result, "artifacts", Map.put(artifacts, "task_evidence", descriptor))}
    end
  rescue
    exception -> {:error, {:coding_task_finalize_error, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:coding_task_finalize_exit, reason}}
    kind, reason -> {:error, {:coding_task_finalize_throw, {kind, reason}}}
  end

  @doc "Archive and acknowledge the exact canonical envelope for every task terminal."
  @impl true
  @spec finalize_terminal_task(String.t(), map(), list(), map() | keyword()) ::
          :ok | {:error, term()}
  def finalize_terminal_task(agent_id, terminal_envelope, controls, context) do
    with :ok <- validate_agent_id(agent_id),
         {:ok, exec_ctx} <- validate_context(context),
         :ok <- validate_exact_context_task_id(context, exec_ctx.task_id),
         {:ok, archive} <-
           build_task_terminal_archive(exec_ctx.task_id, terminal_envelope, controls),
         {:ok, logs_root} <- prepare_task_logs_root(exec_ctx.task_id),
         {:ok, descriptor} <-
           archive_task_terminal(logs_root, exec_ctx.task_id, terminal_envelope, controls),
         :ok <- validate_task_terminal_descriptor(descriptor, logs_root, archive) do
      :ok
    end
  rescue
    _exception -> {:error, :coding_task_terminal_finalize_error}
  catch
    _kind, _reason -> {:error, :coding_task_terminal_finalize_error}
  end

  @doc "Prove and settle post-terminal integration of a published coding candidate."
  @impl true
  @spec adopt_task(String.t(), map(), map(), map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def adopt_task(agent_id, result, request, context) do
    with :ok <- validate_agent_id(agent_id),
         {:ok, exec_ctx} <- validate_context(context),
         {:ok, destination_ref} <- validate_adoption_request(request),
         {:ok, root} <- prepare_task_logs_root(exec_ctx.task_id),
         {:ok, candidate} <-
           verified_adoption_candidate(result, root, exec_ctx.task_id, agent_id),
         {:ok, proof} <-
           Arbor.Actions.prove_coding_branch_adoption(candidate, destination_ref),
         {:ok, adoption_descriptor} <-
           archive_adoption_evidence(root, exec_ctx.task_id, candidate, proof),
         {:ok, settlement} <-
           Arbor.Actions.settle_coding_branch_adoption(candidate, proof) do
      adoption = Map.merge(proof, settlement)

      case adoption_branch_lifecycle(result, adoption) do
        {:ok, branch_lifecycle} ->
          artifacts =
            result
            |> Map.fetch!("artifacts")
            |> Map.put("adoption_evidence", adoption_descriptor)
            |> Map.put("branch_lifecycle", branch_lifecycle)

          {:ok,
           result
           |> Map.put("adoption", adoption)
           |> Map.put("branch_lifecycle", branch_lifecycle)
           |> Map.put("artifacts", artifacts)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    exception -> {:error, {:coding_task_adoption_error, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:coding_task_adoption_exit, reason}}
    kind, reason -> {:error, {:coding_task_adoption_throw, {kind, reason}}}
  end

  # ===========================================================================
  # Validation
  # ===========================================================================

  defp validate_adoption_request(request) when is_map(request) and not is_struct(request) do
    with :ok <- ensure_string_keyed_json_map(request, :non_json_adoption_request),
         true <- MapSet.equal?(Map.keys(request) |> MapSet.new(), @adoption_request_keys),
         destination_ref when is_binary(destination_ref) <- Map.get(request, "destination_ref"),
         true <-
           String.valid?(destination_ref) and String.trim(destination_ref) != "" and
             byte_size(destination_ref) <= @max_destination_ref_bytes and
             not String.contains?(destination_ref, <<0>>) and
             not String.match?(destination_ref, ~r/[\x00-\x1F\x7F]/) do
      {:ok, destination_ref}
    else
      _other -> {:error, :invalid_adoption_request}
    end
  end

  defp validate_adoption_request(_request), do: {:error, :invalid_adoption_request}

  defp verified_adoption_candidate(result, root, task_id, agent_id)
       when is_map(result) and not is_struct(result) do
    with true <- MapSet.member?(@adoptable_statuses, Map.get(result, "status")),
         artifacts when is_map(artifacts) <- Map.get(result, "artifacts"),
         descriptor when is_map(descriptor) <- Map.get(artifacts, "task_evidence"),
         {:ok, descriptor} <- validate_terminal_evidence_descriptor(descriptor, root, task_id),
         {:ok, body} <- read_terminal_evidence_body(descriptor),
         candidate when is_map(candidate) <- Map.get(body, "candidate"),
         true <- MapSet.equal?(Map.keys(candidate) |> MapSet.new(), @adoption_candidate_keys),
         true <- Map.get(candidate, "task_id") == task_id,
         :ok <- candidate_matches_result(candidate, result) do
      {:ok, Map.put(candidate, "principal_id", agent_id)}
    else
      false -> {:error, :coding_task_not_adoptable}
      nil -> {:error, :missing_adoption_candidate_evidence}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_adoption_candidate_evidence}
    end
  end

  defp verified_adoption_candidate(_result, _root, _task_id, _agent_id),
    do: {:error, :invalid_adoption_result}

  defp read_terminal_evidence_body(descriptor) do
    with {:ok, bytes} <- File.read(descriptor["path"]),
         {:ok, body} when is_map(body) <- Jason.decode(bytes) do
      {:ok, body}
    else
      {:error, reason} -> {:error, {:terminal_evidence_unavailable, reason}}
      _other -> {:error, :invalid_terminal_evidence_body}
    end
  end

  defp candidate_matches_result(candidate, result) do
    matches? =
      Enum.all?(
        [
          {"workspace_id", "workspace_id"},
          {"repo_path", "repo_path"},
          {"branch", "branch"},
          {"base_commit", "base_commit"},
          {"candidate_commit", "commit_hash"},
          {"branch_provenance", "branch_provenance"},
          {"evidence_ref", "evidence_ref"}
        ],
        fn {candidate_key, result_key} ->
          Map.get(candidate, candidate_key) == Map.get(result, result_key)
        end
      )

    if matches?, do: :ok, else: {:error, :adoption_candidate_result_mismatch}
  end

  defp archive_adoption_evidence(root, task_id, candidate, proof) do
    store = Config.coding_plan_artifact_store()

    cond do
      not is_atom(store) or not Code.ensure_loaded?(store) ->
        {:error, :coding_plan_artifact_store_unavailable}

      not function_exported?(store, :archive_adoption_evidence, 4) ->
        {:error, :coding_adoption_evidence_store_unavailable}

      true ->
        case store.archive_adoption_evidence(root, task_id, candidate, proof) do
          {:ok, descriptor} when is_map(descriptor) ->
            validate_adoption_evidence_descriptor(descriptor, root, task_id)

          {:error, _reason} = error ->
            error

          _other ->
            {:error, :invalid_coding_adoption_evidence_store_reply}
        end
    end
  end

  defp validate_adoption_evidence_descriptor(descriptor, root, task_id) do
    with {:ok, normalized} <- TaskEvidenceDescriptor.normalize(descriptor),
         true <- normalized["task_id"] == task_id,
         true <- Path.dirname(normalized["path"]) == root,
         true <-
           Regex.match?(
             ~r/\Acoding-adoption-evidence-[0-9a-f]{64}\.json\z/,
             Path.basename(normalized["path"])
           ),
         :ok <- validate_terminal_evidence_file(normalized) do
      {:ok, normalized}
    else
      false -> {:error, :invalid_coding_adoption_evidence_descriptor}
      {:error, reason} -> {:error, {:invalid_coding_adoption_evidence_descriptor, reason}}
      _other -> {:error, :invalid_coding_adoption_evidence_descriptor}
    end
  end

  defp validate_steering_agent_id(agent_id) when is_binary(agent_id) do
    if String.valid?(agent_id) and String.trim(agent_id) != "",
      do: :ok,
      else: {:error, :invalid_agent_id}
  end

  defp validate_steering_agent_id(_agent_id), do: {:error, :invalid_agent_id}

  defp validate_steering_control(control) when is_map(control) and not is_struct(control) do
    with :ok <- ensure_string_keyed_json_map(control, :non_json_control),
         :ok <- ensure_json_encodable(control, :non_json_control),
         :ok <-
           reject_forbidden_keys(control, @forbidden_control_keys, :forbidden_control_key),
         :ok <- reject_unknown_keys(control, @allowed_control_keys, :unknown_control_key),
         {:ok, control_id} <-
           require_bounded_control_field(control, "control_id", @max_control_id_bytes),
         {:ok, task_id} <-
           require_bounded_control_field(control, "task_id", @max_control_task_id_bytes),
         {:ok, message} <-
           require_bounded_control_field(control, "message", @max_control_message_bytes),
         {:ok, target_stage} <- normalize_control_target_stage(control) do
      {:ok,
       %{
         control_id: control_id,
         task_id: task_id,
         message: message,
         target_stage: target_stage
       }}
    end
  end

  defp validate_steering_control(_control), do: {:error, :invalid_control}

  defp require_bounded_control_field(control, field, max_bytes) do
    case Map.fetch(control, field) do
      :error ->
        {:error, {:missing_field, field}}

      {:ok, value} when is_binary(value) ->
        cond do
          byte_size(value) > max_bytes -> {:error, {:field_too_large, field}}
          not String.valid?(value) -> {:error, {:invalid_field_encoding, field}}
          String.trim(value) == "" -> {:error, {:blank_field, field}}
          true -> {:ok, value}
        end

      {:ok, _value} ->
        {:error, {:invalid_field_type, field}}
    end
  end

  defp normalize_control_target_stage(control) do
    case Map.fetch(control, "target_stage") do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        cond do
          byte_size(value) > @max_target_stage_bytes ->
            {:error, {:field_too_large, "target_stage"}}

          not String.valid?(value) ->
            {:error, {:invalid_field_encoding, "target_stage"}}

          String.trim(value) == "" ->
            {:ok, nil}

          true ->
            {:ok, value}
        end

      {:ok, _value} ->
        {:error, {:invalid_field_type, "target_stage"}}
    end
  end

  defp ensure_same_task(task_id, task_id), do: :ok

  defp ensure_same_task(control_task_id, context_task_id) do
    {:error, {:task_id_mismatch, control_task_id, context_task_id}}
  end

  defp ensure_json_encodable(value, error_tag) do
    case Jason.encode(value) do
      {:ok, _encoded} -> :ok
      {:error, _reason} -> {:error, {error_tag, :invalid_encoding}}
    end
  rescue
    _exception -> {:error, {error_tag, :invalid_encoding}}
  end

  # ===========================================================================
  # Managed ACP task control
  # ===========================================================================

  defp build_managed_control(control) do
    correction =
      %{"message" => control.message}
      |> maybe_put_target_stage(control.target_stage)

    with {:ok, correction_json} <- Jason.encode(correction),
         instruction <- follow_up_instruction(correction_json),
         :ok <- ensure_instruction_bound(instruction) do
      managed_control =
        %{
          "control_id" => control.control_id,
          "task_id" => control.task_id,
          "message" => instruction
        }
        |> maybe_put_target_stage(control.target_stage)

      {:ok, managed_control}
    else
      {:error, %Jason.EncodeError{}} -> {:error, :invalid_control_encoding}
      {:error, _reason} = error -> error
    end
  end

  defp maybe_put_target_stage(map, nil), do: map
  defp maybe_put_target_stage(map, target_stage), do: Map.put(map, "target_stage", target_stage)

  defp follow_up_instruction(correction_json) do
    """
    This is a same-task follow-up from the task owner. Apply the task owner's correction in the current worktree and current ACP session, then continue the existing coding task. Any target_stage value below is non-authority context only; it does not change the task, principal, capabilities, worktree, or session.

    TASK_OWNER_CORRECTION_JSON_BEGIN
    #{correction_json}
    TASK_OWNER_CORRECTION_JSON_END

    For compatibility with archived coding graphs, respond with ONLY one valid JSON object and no prose or Markdown: {"status":"implemented","summary":"what changed"} or {"status":"declined","summary":"why no change was made"}. Arbor inspects the workspace for the authoritative outcome, so this object is advisory only.
    """
    |> String.trim()
  end

  defp ensure_instruction_bound(instruction) do
    if byte_size(instruction) <= @max_follow_up_instruction_bytes,
      do: :ok,
      else: {:error, :control_instruction_too_large}
  end

  defp deliver_managed_control(task_id, agent_id, managed_control) do
    result =
      try do
        facade = Config.coding_task_control_facade()
        facade.acp_managed_deliver_task_control(task_id, agent_id, managed_control, [])
      rescue
        _exception -> {:error, :task_control_delivery_failed}
      catch
        :exit, _reason -> {:error, :task_control_delivery_failed}
        _kind, _reason -> {:error, :task_control_delivery_failed}
      end

    adapt_managed_control_result(result)
  end

  defp adapt_managed_control_result({:ok, :queued, :same_session_follow_up}),
    do: {:ok, :queued, :same_session_follow_up}

  defp adapt_managed_control_result({:ok, :delivered, :same_session_follow_up}),
    do: {:ok, :same_session_follow_up}

  defp adapt_managed_control_result({:ok, :deferred, :same_session_follow_up}),
    do: {:error, :deferred}

  defp adapt_managed_control_result({:error, {:not_ready, status}})
       when is_atom(status) or is_binary(status),
       do: {:error, {:not_ready, status}}

  defp adapt_managed_control_result({:error, {:task_control_terminal, :not_delivered, _reason}}),
    do: {:error, :not_delivered}

  defp adapt_managed_control_result(
         {:error, {:task_control_terminal, :delivery_unknown, _reason}}
       ),
       do: {:error, :delivery_unknown}

  defp adapt_managed_control_result({:error, {:task_control_terminal, :cancelled, _reason}}),
    do: {:error, :cancelled}

  defp adapt_managed_control_result({:error, {:task_control_terminal, status, _reason}})
       when status in [:not_delivered, :delivery_unknown, :cancelled],
       do: {:error, :unsupported}

  defp adapt_managed_control_result({:error, {reason, _detail}})
       when reason in [
              :unsupported,
              :not_supported,
              :task_control_unsupported,
              :nonrecoverable,
              :non_recoverable
            ],
       do: {:error, :unsupported}

  defp adapt_managed_control_result({:error, reason}) when is_atom(reason) do
    if MapSet.member?(@terminal_control_errors, reason),
      do: {:error, :unsupported},
      else: {:error, reason}
  end

  defp adapt_managed_control_result({:ok, _status, _mode}), do: {:error, :unsupported}
  defp adapt_managed_control_result(_result), do: {:error, :task_control_delivery_failed}

  defp validate_agent_id(agent_id) when is_binary(agent_id) do
    case String.trim(agent_id) do
      "" -> {:error, :invalid_agent_id}
      _ -> :ok
    end
  end

  defp validate_agent_id(_agent_id), do: {:error, :invalid_agent_id}

  defp validate_finalize_result(result) when is_map(result) and not is_struct(result) do
    with :ok <- ensure_string_keyed_json_map(result, :non_json_result),
         :ok <- reject_unknown_keys(result, @finalize_result_keys, :unknown_result_key),
         {:ok, _status} <- require_nonblank(result, "status"),
         {:ok, canonical_status} <- require_nonblank(result, "canonical_status"),
         true <- OutcomeMapper.terminal_status?(Map.fetch!(result, "status")),
         true <- OutcomeMapper.terminal_status?(canonical_status),
         :ok <- validate_finalize_outcome(result, canonical_status),
         :ok <- validate_finalize_artifacts(Map.get(result, "artifacts")),
         :ok <- validate_finalize_optional_data(result),
         :ok <- validate_finalize_capacity_consistency(result) do
      :ok
    else
      false -> {:error, {:invalid_finalize_result, :not_successful}}
      {:error, _reason} = error -> error
      _ -> {:error, {:invalid_finalize_result, :malformed}}
    end
  end

  defp validate_finalize_result(_result), do: {:error, :invalid_finalize_result}

  defp validate_finalize_outcome(result, canonical_status) do
    outcome = Map.get(result, "outcome")

    if OutcomeMapper.compatible_with_status?(outcome, canonical_status),
      do: :ok,
      else: {:error, {:invalid_finalize_result, :outcome}}
  end

  defp normalize_finalize_result(result) do
    with :ok <- validate_finalize_result(result),
         {:ok, normalized} <- normalize_finalize_capacity(result) do
      {:ok, normalized}
    end
  end

  defp normalize_finalize_capacity(result),
    do: ValidationCapacityTerminal.normalize_result(result, :finalize)

  defp validate_finalize_task_id(task_id)
       when is_binary(task_id) and byte_size(task_id) <= @max_finalize_task_id_bytes do
    if String.valid?(task_id) and String.trim(task_id) != "" and
         not String.contains?(task_id, <<0>>) and
         not String.match?(task_id, ~r/[\x00-\x1F\x7F]/),
       do: :ok,
       else: {:error, {:invalid_task_id, :control_character}}
  end

  defp validate_finalize_task_id(_task_id),
    do: {:error, {:invalid_task_id, :invalid_value}}

  defp validate_finalize_artifacts(artifacts)
       when is_map(artifacts) and not is_struct(artifacts) do
    required = @artifact_descriptor_keys
    keys = Map.keys(artifacts) |> MapSet.new()

    with true <- MapSet.subset?(required, keys),
         true <- MapSet.subset?(keys, MapSet.union(required, @finalize_artifact_optional_keys)),
         :ok <-
           validate_nonblank_binary(Map.get(artifacts, "coding_plan_path"), "coding_plan_path"),
         :ok <-
           validate_nonblank_binary(
             Map.get(artifacts, "coding_pipeline_path"),
             "coding_pipeline_path"
           ),
         :ok <-
           validate_nonblank_binary(
             Map.get(artifacts, "compile_manifest_path"),
             "compile_manifest_path"
           ),
         :ok <- validate_hash(Map.get(artifacts, "graph_hash"), "graph_hash"),
         :ok <-
           validate_nonblank_binary(Map.get(artifacts, "compiler_version"), "compiler_version"),
         :ok <-
           validate_finalize_artifact_descriptor(
             artifacts,
             "workspace_release",
             WorkspaceReleaseDescriptor
           ),
         :ok <-
           validate_finalize_artifact_descriptor(
             artifacts,
             "branch_lifecycle",
             BranchLifecycleDescriptor
           ) do
      :ok
    else
      false -> {:error, {:invalid_finalize_artifacts, :fields}}
      {:error, _reason} = error -> error
      _ -> {:error, {:invalid_finalize_artifacts, :fields}}
    end
  end

  defp validate_finalize_artifacts(_artifacts),
    do: {:error, {:invalid_finalize_artifacts, :expected_map}}

  defp validate_finalize_optional_data(result) do
    with :ok <- validate_finalize_json_field(result, "validation", &is_list/1),
         :ok <- validate_finalize_verification_report(result),
         :ok <- validate_finalize_json_field(result, "review", &is_map/1),
         :ok <-
           validate_finalize_descriptor_field(
             result,
             "branch_lifecycle",
             BranchLifecycleDescriptor
           ) do
      :ok
    end
  end

  defp validate_finalize_verification_report(result) do
    case Map.fetch(result, "verification_report") do
      :error ->
        :ok

      {:ok, report} ->
        if VerificationReport.valid?(report),
          do: :ok,
          else: {:error, {:invalid_finalize_field, "verification_report"}}
    end
  end

  defp validate_finalize_capacity_consistency(result),
    do: ValidationCapacityTerminal.validate_consistency(result, :finalize)

  defp validate_finalize_artifact_descriptor(artifacts, key, contract) do
    case Map.fetch(artifacts, key) do
      :error ->
        :ok

      {:ok, value} ->
        if contract.valid?(value), do: :ok, else: {:error, {:invalid_finalize_artifact, key}}
    end
  end

  defp validate_finalize_descriptor_field(result, key, contract) do
    case Map.fetch(result, key) do
      :error ->
        :ok

      {:ok, value} ->
        if contract.valid?(value), do: :ok, else: {:error, {:invalid_finalize_field, key}}
    end
  end

  defp adoption_branch_lifecycle(result, adoption) do
    branch_retired? = Map.get(adoption, "branch_retired") == true

    attrs = %{
      "branch_status" => if(branch_retired?, do: "retired", else: "preserved"),
      "cleanup_status" => "complete",
      "branch_preserved_reason" =>
        if(branch_retired?,
          do: nil,
          else: Map.get(adoption, "branch_preserved_reason", "branch_preserved")
        ),
      "evidence_ref" => Map.get(adoption, "evidence_ref"),
      "published_commit" => Map.get(result, "commit_hash")
    }

    case BranchLifecycleDescriptor.normalize(attrs) do
      {:ok, descriptor} -> {:ok, descriptor}
      {:error, reason} -> {:error, {:invalid_adoption_branch_lifecycle, reason}}
    end
  end

  defp validate_finalize_json_field(result, key, predicate) do
    case Map.fetch(result, key) do
      :error ->
        :ok

      {:ok, nil} ->
        :ok

      {:ok, value} ->
        if predicate.(value) and not is_struct(value),
          do: ensure_json_value(value),
          else: {:error, {:invalid_finalize_field, key}}
    end
  end

  defp validate_finalize_controls(controls) when is_list(controls) do
    if length(controls) > @max_finalize_controls do
      {:error, {:invalid_finalize_controls, :too_many}}
    else
      Enum.reduce_while(controls, :ok, fn control, :ok ->
        if is_map(control) and not is_struct(control) do
          case ensure_string_keyed_json_map(control, :non_json_control) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end
        else
          {:halt, {:error, {:invalid_finalize_control, :expected_map}}}
        end
      end)
    end
  end

  defp validate_finalize_controls(_controls),
    do: {:error, {:invalid_finalize_controls, :expected_list}}

  defp validate_exact_context_task_id(context, task_id) do
    if is_map(context) and Map.get(context, "task_id") == task_id,
      do: :ok,
      else: {:error, :task_terminal_context_mismatch}
  end

  defp build_task_terminal_archive(task_id, terminal_envelope, controls) do
    case TaskTerminalArchiveCore.build(task_id, terminal_envelope, controls) do
      {:ok, archive} ->
        {:ok, archive}

      {:error, {:invalid_terminal_task_id, :invalid_value}} ->
        case validate_finalize_task_id(task_id) do
          {:error, _reason} = error -> error
          :ok -> {:error, {:invalid_task_id, :invalid_value}}
        end

      {:error, {:invalid_terminal_controls, _reason}} ->
        {:error, :invalid_reconciled_terminal_controls}

      {:error, {:invalid_terminal_control, _reason}} ->
        {:error, :invalid_reconciled_terminal_controls}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_finalize_artifact_files(result, root) do
    artifacts = Map.fetch!(result, "artifacts")

    expected = %{
      "coding_plan_path" => Path.join(root, "coding-plan.json"),
      "coding_pipeline_path" => Path.join(root, "coding-pipeline.dot"),
      "compile_manifest_path" => Path.join(root, "coding-compile-manifest.json")
    }

    with :ok <- validate_finalize_artifact_paths(artifacts, expected),
         :ok <- validate_regular_terminal_file(expected["coding_plan_path"]),
         :ok <- validate_regular_terminal_file(expected["coding_pipeline_path"]),
         :ok <- validate_regular_terminal_file(expected["compile_manifest_path"]) do
      :ok
    end
  end

  defp validate_finalize_artifact_paths(artifacts, expected) do
    Enum.reduce_while(@artifact_path_keys, :ok, fn key, :ok ->
      expected_path = Map.fetch!(expected, key)

      case Map.get(artifacts, key) do
        path when is_binary(path) ->
          if path == expected_path,
            do: {:cont, :ok},
            else: {:halt, {:error, {:invalid_finalize_artifact_path, key}}}

        _ ->
          {:halt, {:error, {:invalid_finalize_artifact_path, key}}}
      end
    end)
  end

  defp validate_regular_terminal_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        if Bitwise.band(mode, 0o777) == 0o600,
          do: :ok,
          else: {:error, {:invalid_finalize_artifact_file, :insecure_mode}}

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, {:invalid_finalize_artifact_file, :symlink}}

      {:ok, _stat} ->
        {:error, {:invalid_finalize_artifact_file, :not_regular}}

      {:error, reason} ->
        {:error, {:invalid_finalize_artifact_file, reason}}
    end
  end

  defp archive_terminal_evidence(root, task_id, result, controls) do
    store = Config.coding_plan_artifact_store()

    cond do
      not is_atom(store) ->
        {:error, :coding_plan_artifact_store_unavailable}

      not Code.ensure_loaded?(store) ->
        {:error, :coding_plan_artifact_store_unavailable}

      not function_exported?(store, :archive_terminal_evidence, 4) ->
        {:error, :coding_plan_artifact_store_unavailable}

      true ->
        invoke_terminal_evidence_store(store, root, task_id, result, controls)
    end
  end

  defp archive_task_terminal(root, task_id, terminal_envelope, controls) do
    store = Config.coding_plan_artifact_store()

    cond do
      not is_atom(store) ->
        {:error, :coding_plan_artifact_store_unavailable}

      not Code.ensure_loaded?(store) ->
        {:error, :coding_plan_artifact_store_unavailable}

      not function_exported?(store, :archive_task_terminal, 4) ->
        {:error, :coding_plan_artifact_store_unavailable}

      true ->
        invoke_task_terminal_store(store, root, task_id, terminal_envelope, controls)
    end
  end

  defp invoke_task_terminal_store(store, root, task_id, terminal_envelope, controls) do
    case store.archive_task_terminal(root, task_id, terminal_envelope, controls) do
      {:ok, descriptor} when is_map(descriptor) -> {:ok, descriptor}
      {:error, _reason} -> {:error, :coding_task_terminal_archive_failed}
      _other -> {:error, :invalid_coding_task_terminal_store_reply}
    end
  rescue
    _exception -> {:error, :coding_task_terminal_archive_failed}
  catch
    _kind, _reason -> {:error, :coding_task_terminal_archive_failed}
  end

  defp validate_task_terminal_descriptor(descriptor, root, archive) do
    expected_path = Path.join(root, "coding-task-terminal.json")
    expected_descriptor = Map.put(archive.descriptor_fields, "path", expected_path)

    with :ok <- validate_json_object(descriptor, :task_terminal_descriptor),
         true <- descriptor === expected_descriptor,
         {:ok, %File.Stat{type: :regular, mode: mode}} <- File.lstat(expected_path),
         true <- Bitwise.band(mode, 0o777) == 0o600,
         {:ok, bytes} <- File.read(expected_path),
         true <- bytes === archive.encoded do
      :ok
    else
      _ -> {:error, :invalid_coding_task_terminal_descriptor}
    end
  end

  defp invoke_terminal_evidence_store(store, root, task_id, result, controls) do
    case store.archive_terminal_evidence(root, task_id, result, controls) do
      {:ok, descriptor} when is_map(descriptor) -> {:ok, descriptor}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_coding_terminal_evidence_store_reply}
    end
  rescue
    exception -> {:error, {:coding_terminal_evidence_store_error, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:coding_terminal_evidence_store_exit, reason}}
    kind, reason -> {:error, {:coding_terminal_evidence_store_throw, {kind, reason}}}
  end

  defp validate_terminal_evidence_descriptor(descriptor, root, task_id) do
    with {:ok, normalized} <- TaskEvidenceDescriptor.normalize(descriptor),
         :ok <- validate_terminal_evidence_descriptor_identity(normalized, root, task_id),
         :ok <- validate_terminal_evidence_file(normalized) do
      {:ok, normalized}
    else
      {:error, reason} -> {:error, {:invalid_coding_terminal_evidence_descriptor, reason}}
      _ -> {:error, :invalid_coding_terminal_evidence_descriptor}
    end
  end

  defp validate_terminal_evidence_descriptor_identity(descriptor, root, task_id) do
    expected_path = Path.join(root, "coding-terminal-evidence.json")

    if descriptor["task_id"] == task_id and descriptor["path"] == expected_path,
      do: :ok,
      else: {:error, :terminal_evidence_descriptor_mismatch}
  end

  defp validate_terminal_evidence_file(descriptor) do
    with :ok <- validate_regular_terminal_file(descriptor["path"]),
         {:ok, bytes} <- File.read(descriptor["path"]),
         true <- byte_size(bytes) == descriptor["byte_size"],
         true <- sha256(bytes) == descriptor["sha256"] do
      :ok
    else
      false -> {:error, :terminal_evidence_file_mismatch}
      {:error, reason} -> {:error, {:terminal_evidence_file_unavailable, reason}}
      _ -> {:error, :terminal_evidence_file_mismatch}
    end
  end

  defp validate_context(context) when is_map(context) and not is_struct(context) do
    with :ok <- ensure_string_keyed_json_map(context, :non_json_context),
         :ok <- reject_forbidden_keys(context, @forbidden_context_keys, :forbidden_context_key),
         :ok <- reject_unknown_keys(context, @allowed_context_keys, :unknown_context_key),
         {:ok, task_id} <- require_nonblank(context, "task_id"),
         {:ok, extras} <- extract_context_extras(context) do
      {:ok, Map.merge(%{task_id: task_id}, extras)}
    end
  end

  defp validate_context(_context), do: {:error, :invalid_context}

  defp require_nonblank(map, field) do
    case Map.get(map, field) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:blank_field, field}}
          trimmed -> {:ok, trimmed}
        end

      nil ->
        {:error, {:missing_field, field}}

      _other ->
        {:error, {:invalid_field_type, field}}
    end
  end

  defp extract_context_extras(context) do
    Enum.reduce_while(["timeout", "caller_id", "metadata"], {:ok, %{}}, fn key, {:ok, acc} ->
      case Map.fetch(context, key) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, nil} ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          case normalize_context_extra(key, value) do
            {:ok, normalized} ->
              atom_key =
                case key do
                  "timeout" -> :timeout
                  "caller_id" -> :caller_id
                  "metadata" -> :metadata
                end

              {:cont, {:ok, Map.put(acc, atom_key, normalized)}}

            {:error, _} = err ->
              {:halt, err}
          end
      end
    end)
  end

  defp normalize_context_extra("timeout", value)
       when is_integer(value) and value > 0 and not is_boolean(value) do
    {:ok, value}
  end

  defp normalize_context_extra("timeout", _value), do: {:error, {:invalid_field_type, "timeout"}}

  defp normalize_context_extra("caller_id", value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:blank_field, "caller_id"}}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_context_extra("caller_id", _value),
    do: {:error, {:invalid_field_type, "caller_id"}}

  defp normalize_context_extra("metadata", value)
       when is_map(value) and not is_struct(value) do
    case ensure_string_keyed_json_map(value, :non_json_context) do
      :ok -> {:ok, value}
      {:error, _} = err -> err
    end
  end

  defp normalize_context_extra("metadata", _value),
    do: {:error, {:invalid_field_type, "metadata"}}

  defp reject_forbidden_keys(map, forbidden, error_tag) do
    case Enum.find(Map.keys(map), &MapSet.member?(forbidden, &1)) do
      nil -> :ok
      key -> {:error, {error_tag, key}}
    end
  end

  defp reject_unknown_keys(map, allowed, error_tag) do
    case Enum.find(Map.keys(map), &(not MapSet.member?(allowed, &1))) do
      nil -> :ok
      key -> {:error, {error_tag, key}}
    end
  end

  # Strict JSON boundary: only string keys, no structs/keywords/coercion.
  # Rejects maps that would require stringifying atom keys or merging
  # conflicting coercible keys (e.g. :task and "task").
  defp ensure_string_keyed_json_map(map, error_tag) when is_map(map) and not is_struct(map) do
    Enum.reduce_while(map, :ok, fn {key, value}, :ok ->
      cond do
        not is_binary(key) ->
          {:halt, {:error, {error_tag, :non_string_key}}}

        true ->
          case ensure_json_value(value) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {error_tag, reason}}}
          end
      end
    end)
  end

  defp ensure_json_value(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v),
    do: :ok

  defp ensure_json_value(list) when is_list(list) do
    if Keyword.keyword?(list) and list != [] do
      {:error, :keyword_not_json}
    else
      Enum.reduce_while(list, :ok, fn item, :ok ->
        case ensure_json_value(item) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  defp ensure_json_value(map) when is_map(map) and not is_struct(map) do
    ensure_string_keyed_json_map(map, :nested_non_json)
  end

  defp ensure_json_value(%_{}), do: {:error, :struct_not_json}
  defp ensure_json_value(v) when is_atom(v), do: {:error, :atom_not_json}
  defp ensure_json_value(v) when is_pid(v), do: {:error, :pid_not_json}
  defp ensure_json_value(v) when is_function(v), do: {:error, :function_not_json}
  defp ensure_json_value(v) when is_reference(v), do: {:error, :reference_not_json}
  defp ensure_json_value(v) when is_port(v), do: {:error, :port_not_json}
  defp ensure_json_value(v) when is_tuple(v), do: {:error, :tuple_not_json}
  defp ensure_json_value(_), do: {:error, :non_json_value}

  # ===========================================================================
  # Identity / graph / engine opts
  # ===========================================================================

  defp admit_coding_plan(task, agent_id) do
    with {:ok, plan} <-
           Normalizer.normalize_task(task)
           |> map_admission_failure(:plan),
         {:ok, template_path} <-
           resolve_template_path()
           |> map_admission_failure(:readiness),
         {:ok, canonical_plan, compilation} <-
           Readiness.prepare(plan, template_path: template_path)
           |> map_admission_failure(:readiness),
         readiness_observed_at = DateTime.utc_now(),
         {:ok, readiness_report} <-
           Readiness.check_prepared(
             canonical_plan,
             compilation,
             mode: :live,
             agent_id: agent_id,
             observed_at: readiness_observed_at
           )
           |> map_admission_failure(:readiness, readiness_observed_at),
         :ok <- admit_readiness(readiness_report, readiness_observed_at) do
      {:ok, canonical_plan, compilation, readiness_report}
    end
  end

  defp map_admission_failure({:error, reason}, stage),
    do: coding_admission_error(stage, reason, DateTime.utc_now())

  defp map_admission_failure(result, _stage), do: result

  defp map_admission_failure({:error, reason}, stage, observed_at),
    do: coding_admission_error(stage, reason, observed_at)

  defp map_admission_failure(result, _stage, _observed_at), do: result

  defp admit_readiness(%{"status" => status}, _observed_at)
       when status in ["ready", "degraded"],
       do: :ok

  defp admit_readiness(%{"status" => "blocked", "diagnostics" => diagnostics}, observed_at)
       when is_list(diagnostics) do
    case Enum.find(diagnostics, &(&1["decision"] == "blocked")) do
      diagnostic when is_map(diagnostic) ->
        coding_admission_error(diagnostic)

      _ ->
        coding_admission_error(:readiness, :invalid_readiness_report, observed_at)
    end
  end

  defp admit_readiness(_report, observed_at),
    do: coding_admission_error(:readiness, :invalid_readiness_report, observed_at)

  defp coding_admission_error(stage, reason, observed_at) do
    case Readiness.admission_diagnostic(stage, reason, observed_at) do
      {:ok, diagnostic} -> coding_admission_error(diagnostic)
      {:error, _reason} -> {:error, :coding_admission_contract_unavailable}
    end
  end

  defp coding_admission_error(diagnostic) do
    with {:ok, canonical_diagnostic} <- Diagnostic.normalize(diagnostic),
         {:ok, outcome} <- TaskOutcome.from_code("coding_admission_failed"),
         {:ok, failure} <-
           AdmissionFailure.normalize(%{
             "status" => "coding_admission_failed",
             "diagnostic" => canonical_diagnostic,
             "outcome" => TaskOutcome.to_map(outcome)
           }) do
      {:error, {:coding_admission_failed, failure}}
    else
      {:error, _reason} -> {:error, :coding_admission_contract_unavailable}
    end
  end

  defp map_post_readiness_immutable_failure({:ok, _value} = result, _report, _stage),
    do: result

  defp map_post_readiness_immutable_failure({:error, reason} = error, report, stage) do
    case immutable_drift_code(stage, reason) do
      nil -> error
      code -> execution_state_drift_error(report, code)
    end
  end

  defp immutable_drift_code(
         :archive,
         {:invalid_coding_plan_artifact_store_reply, reason}
       )
       when reason in [
              :artifact_content_mismatch,
              :descriptor_graph_hash_mismatch,
              :descriptor_compiler_version_mismatch
            ],
       do: "immutable_artifact_state_drift"

  defp immutable_drift_code(
         :execution_boundary,
         {:coding_execution_preflight_failed, :archived_graph_mismatch}
       ),
       do: "immutable_graph_state_drift"

  defp immutable_drift_code(
         :execution_boundary,
         {:coding_execution_preflight_failed, {:prepared_compilation_mismatch, _reason}}
       ),
       do: "prepared_compilation_state_drift"

  defp immutable_drift_code(
         :execution_boundary,
         {:coding_execution_preflight_failed, reason}
       ) do
    if execution_binding_drift?(reason),
      do: "execution_binding_state_drift",
      else: nil
  end

  defp immutable_drift_code(_stage, _reason), do: nil

  defp execution_binding_drift?({:execution_manifest_mismatch, _sections}), do: true
  defp execution_binding_drift?({:execution_manifest_field_mismatch, _field}), do: true
  defp execution_binding_drift?({:invalid_execution_manifest_field, _field}), do: true
  defp execution_binding_drift?(:invalid_execution_manifest), do: true
  defp execution_binding_drift?(:invalid_action_bindings), do: true
  defp execution_binding_drift?(:invalid_handler_bindings), do: true
  defp execution_binding_drift?(_reason), do: false

  defp execution_state_drift_error(admitted_report, code) do
    observed_at = DateTime.utc_now() |> DateTime.to_iso8601(:extended)
    admitted_observed_at = Map.fetch!(admitted_report, "observed_at")
    admitted_evidence_ref = json_evidence_ref(admitted_report)

    evidence_ref =
      json_evidence_ref(%{
        "admitted_evidence_ref" => admitted_evidence_ref,
        "admitted_observed_at" => admitted_observed_at,
        "code" => code,
        "gate_id" => "immutable_execution_boundary",
        "observed_at" => observed_at,
        "plan_digest" => Map.fetch!(admitted_report, "plan_digest")
      })

    {:ok, diagnostic} =
      Diagnostic.new(%{
        version: Diagnostic.schema_version(),
        gate_id: "immutable_execution_boundary",
        phase: "preflight",
        decision: "blocked",
        code: code,
        observed_at: observed_at,
        message:
          "Readiness observed at #{admitted_observed_at} (#{admitted_evidence_ref}) no longer matches the immutable execution boundary.",
        remediation:
          "Repeat readiness and dispatch with unchanged reviewed artifacts and bindings.",
        evidence_ref: evidence_ref
      })

    {:ok, drift_report} =
      ReadinessReport.new(%{
        version: ReadinessReport.schema_version(),
        status: "blocked",
        plan_digest: Map.fetch!(admitted_report, "plan_digest"),
        observed_at: observed_at,
        diagnostics: [Diagnostic.to_map(diagnostic)]
      })

    {:error, {:coding_execution_state_drift, ReadinessReport.to_map(drift_report)}}
  end

  defp json_evidence_ref(value) do
    encoded = value |> canonical_json() |> Jason.encode!()
    "sha256:" <> sha256(encoded)
  end

  defp canonical_json(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, nested} -> {key, canonical_json(nested)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonical_json(value) when is_list(value), do: Enum.map(value, &canonical_json/1)
  defp canonical_json(value), do: value

  defp resolve_template_path do
    path = Config.coding_pipeline_path()

    cond do
      not is_binary(path) or String.trim(path) == "" ->
        {:error, :coding_pipeline_unavailable}

      File.regular?(path) ->
        {:ok, path}

      true ->
        {:error, {:coding_pipeline_unavailable, path}}
    end
  end

  defp validate_nonblank_binary(value, _field)
       when is_binary(value) and byte_size(value) > 0 do
    if String.valid?(value) and String.trim(value) != "",
      do: :ok,
      else: {:error, :invalid_binary}
  end

  defp validate_nonblank_binary(_value, field), do: {:error, {:invalid_field, field}}

  defp validate_hash(value, field) do
    with :ok <- validate_nonblank_binary(value, field),
         true <- Regex.match?(~r/^[0-9a-f]{64}$/, value) do
      :ok
    else
      false -> {:error, {:invalid_hash, field}}
      {:error, _reason} = error -> error
    end
  end

  # `resolve_within/2` compares whole path segments after both values have
  # been realpathed.
  defp contained_in?(root, path) do
    case SafePath.resolve_within(path, root) do
      {:ok, ^path} -> true
      _ -> false
    end
  end

  defp archive_compilation(root, %Plan{} = plan, %Compilation{} = compilation) do
    store = Config.coding_plan_artifact_store()

    cond do
      not is_atom(store) ->
        {:error, :coding_plan_artifact_store_unavailable}

      not Code.ensure_loaded?(store) ->
        {:error, :coding_plan_artifact_store_unavailable}

      not function_exported?(store, :archive, 4) ->
        {:error, :coding_plan_artifact_store_unavailable}

      true ->
        with {:ok, verified_root} <- verify_task_logs_directory(root, Path.dirname(root)) do
          invoke_artifact_store(store, verified_root, plan, compilation)
        end
    end
  end

  defp invoke_artifact_store(store, root, plan, compilation) do
    case store.archive(
           root,
           Plan.to_map(plan),
           compilation.dot_source,
           compilation.manifest
         ) do
      {:ok, descriptor} ->
        validate_artifact_descriptor(descriptor, root, plan, compilation)

      {:error, _reason} = error ->
        error

      _other ->
        {:error, :invalid_coding_plan_artifact_store_reply}
    end
  rescue
    error -> {:error, {:coding_plan_artifact_store_error, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:coding_plan_artifact_store_exit, reason}}
    kind, reason -> {:error, {:coding_plan_artifact_store_throw, {kind, reason}}}
  end

  defp validate_artifact_descriptor(descriptor, root, plan, compilation) do
    with :ok <- validate_json_object(descriptor, :artifact_descriptor),
         :ok <- validate_descriptor_keys(descriptor),
         :ok <- validate_descriptor_values(descriptor),
         :ok <- validate_descriptor_identity(descriptor, compilation),
         {:ok, canonical_root} <- canonical_artifact_root(root),
         :ok <- validate_descriptor_paths(descriptor, canonical_root),
         :ok <- validate_archived_contents(descriptor, plan, compilation) do
      {:ok, descriptor}
    else
      {:error, reason} -> {:error, {:invalid_coding_plan_artifact_store_reply, reason}}
    end
  end

  defp validate_descriptor_keys(descriptor) do
    keys = Map.keys(descriptor) |> MapSet.new()

    if MapSet.equal?(keys, @artifact_descriptor_keys),
      do: :ok,
      else: {:error, :unexpected_descriptor_keys}
  end

  defp validate_descriptor_values(descriptor) do
    Enum.reduce_while(@artifact_descriptor_keys, :ok, fn key, :ok ->
      case validate_nonblank_binary(Map.get(descriptor, key), key) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_descriptor_identity(descriptor, compilation) do
    cond do
      descriptor["graph_hash"] != compilation.graph_hash ->
        {:error, :descriptor_graph_hash_mismatch}

      descriptor["compiler_version"] != compilation.compiler_version ->
        {:error, :descriptor_compiler_version_mismatch}

      true ->
        :ok
    end
  end

  defp canonical_artifact_root(root) do
    expanded_root = Path.expand(root)

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(expanded_root),
         {:ok, canonical_root} <- SafePath.resolve_real(expanded_root),
         true <- canonical_root == expanded_root,
         true <- File.dir?(canonical_root) do
      {:ok, canonical_root}
    else
      _ -> {:error, :artifact_root_missing}
    end
  end

  defp validate_descriptor_paths(descriptor, canonical_root) do
    Enum.reduce_while(@artifact_path_keys, :ok, fn key, :ok ->
      path = descriptor[key]

      result =
        with true <- SafePath.absolute?(path),
             {:ok, canonical_path} <- SafePath.resolve_real(path),
             true <- File.regular?(canonical_path),
             true <- contained_in?(canonical_root, canonical_path) do
          :ok
        else
          _ -> {:error, {:invalid_artifact_path, key}}
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_archived_contents(descriptor, plan, compilation) do
    with {:ok, dot_source} <- File.read(descriptor["coding_pipeline_path"]),
         true <- dot_source == compilation.dot_source,
         {:ok, plan_json} <- File.read(descriptor["coding_plan_path"]),
         {:ok, archived_plan} <- Jason.decode(plan_json),
         true <- archived_plan == Plan.to_map(plan),
         {:ok, manifest_json} <- File.read(descriptor["compile_manifest_path"]),
         {:ok, archived_manifest} <- Jason.decode(manifest_json),
         true <- archived_manifest == compilation.manifest do
      :ok
    else
      false -> {:error, :artifact_content_mismatch}
      {:error, _reason} -> {:error, :artifact_content_unreadable}
    end
  end

  defp verify_execution_boundary(graph_path, %Plan{} = plan, %Compilation{} = compilation) do
    with :ok <- validate_prepared_execution_compilation(compilation, plan),
         {:ok, dot_source} <- File.read(graph_path),
         true <- dot_source == compilation.dot_source,
         true <- sha256(dot_source) == compilation.graph_hash,
         {:ok, graph} <- parse_execution_graph(dot_source),
         {:ok, compiled_graph} <- IRCompiler.compile(graph),
         {:ok, profile} <- Profiles.fetch_executable(plan.validation_profile),
         {:ok, validation_timeout_ms} <-
           Profiles.validation_timeout(profile, plan.budgets["wall_clock_ms"]),
         {:ok, validation_test_stage_timeout_ms} <-
           Profiles.validation_test_stage_timeout(profile, plan.budgets["wall_clock_ms"]),
         {:ok, validation_stage_timeout_ms} <-
           Profiles.validation_stage_timeout(profile, plan.budgets["wall_clock_ms"]),
         {:ok, semantic_preflight_opts} <-
           execution_boundary_semantic_preflight_opts(
             plan,
             validation_timeout_ms,
             validation_test_stage_timeout_ms,
             validation_stage_timeout_ms
           ),
         :ok <- Profiles.validate_requirements(profile, compiled_graph),
         :ok <-
           SemanticPreflight.validate(
             compiled_graph,
             profile["semantic_policy"],
             semantic_preflight_opts
           ),
         {:ok, live_catalog} <- ActionCatalog.snapshot(),
         {:ok, pinned_action_bindings} <-
           ExecutionManifest.verify(
             compilation.execution_manifest,
             compilation.execution_manifest_digest,
             compiled_graph,
             live_catalog,
             compilation.graph_hash
           ),
         {:ok, pinned_handler_bindings} <-
           ExecutionManifest.handler_binding_index(compilation.execution_manifest) do
      {:ok, {pinned_action_bindings, pinned_handler_bindings}}
    else
      false -> {:error, {:coding_execution_preflight_failed, :archived_graph_mismatch}}
      {:error, reason} -> {:error, {:coding_execution_preflight_failed, reason}}
      _other -> {:error, {:coding_execution_preflight_failed, :invalid_preflight_result}}
    end
  rescue
    exception ->
      {:error, {:coding_execution_preflight_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:coding_execution_preflight_failed, {kind, reason}}}
  end

  # Re-derive the compiler's complete semantic policy projection from the
  # normalized plan. Keeping this independent from compiler output makes any
  # future compile/boundary drift fail closed before the runner is invoked.
  defp execution_boundary_semantic_preflight_opts(
         %Plan{} = plan,
         validation_timeout_ms,
         validation_test_stage_timeout_ms,
         validation_stage_timeout_ms
       ) do
    with {:ok, {checkpoint_policy, checkpoint_work_packet_json}} <-
           execution_boundary_checkpoint_binding(plan) do
      {:ok,
       [
         review_profile: plan.review_profile,
         worker_use_pool: plan.worker["use_pool"],
         worker_resume_session_id: plan.worker["resume_session_id"],
         worker_permission_mode: plan.worker["permission_mode"],
         worker_model: plan.worker["model"],
         checkpoint_policy: checkpoint_policy,
         checkpoint_work_packet_json: checkpoint_work_packet_json,
         rework_max_cycles: plan.rework["max_cycles"],
         validation_timeout_ms: validation_timeout_ms,
         validation_test_stage_timeout_ms: validation_test_stage_timeout_ms,
         validation_stage_timeout_ms: validation_stage_timeout_ms
       ]}
    end
  end

  defp execution_boundary_checkpoint_binding(%Plan{version: 2, work_packet: work_packet})
       when is_map(work_packet) do
    with {:ok, checkpoint_policy} <- Map.fetch(work_packet, "checkpoint_policy"),
         {:ok, work_packet_json} <- WorkPacket.canonical_bytes(work_packet) do
      {:ok, {checkpoint_policy, work_packet_json}}
    end
  end

  defp execution_boundary_checkpoint_binding(%Plan{}), do: {:ok, {"direct", "{}"}}

  defp validate_prepared_execution_compilation(compilation, plan) do
    case Compilation.validate(compilation, plan) do
      {:ok, ^compilation} -> :ok
      {:ok, _other} -> {:error, {:prepared_compilation_mismatch, :unexpected_compilation}}
      {:error, reason} -> {:error, {:prepared_compilation_mismatch, reason}}
      _other -> {:error, {:prepared_compilation_mismatch, :invalid_validation_result}}
    end
  end

  defp parse_execution_graph(dot_source) do
    case Parser.parse(dot_source) do
      {:ok, graph} -> {:ok, graph}
      {:ok, _graph, errors} -> {:error, {:execution_graph_parse_failed, errors}}
      {:error, reason} -> {:error, {:execution_graph_parse_failed, reason}}
    end
  end

  defp validate_json_object(value, error_tag) when is_map(value) and not is_struct(value) do
    case ensure_string_keyed_json_map(value, error_tag) do
      :ok -> :ok
      {:error, reason} -> {:error, {error_tag, reason}}
    end
  end

  defp validate_json_object(_value, error_tag), do: {:error, {error_tag, :expected_map}}

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp security_facade do
    security = Config.security_module()

    if is_atom(security) and Code.ensure_loaded?(security) and
         function_exported?(security, :load_signing_key, 1) and
         function_exported?(security, :build_signing_authority_acquisition_proof, 3) and
         function_exported?(security, :open_signing_authority, 1) and
         function_exported?(security, :sign_with_authority, 2) and
         function_exported?(security, :close_signing_authority, 1) do
      {:ok, security}
    else
      {:error, :security_unavailable}
    end
  end

  # The decrypted key exists only while the owner-bound possession proof is
  # constructed. The broker retains the reload-stable authority, never this
  # key or a closure over it.
  defp acquire_signing_authority(security, agent_id) do
    with {:ok, private_key} <- security.load_signing_key(agent_id),
         true <- is_binary(private_key) and private_key != "",
         {:ok, proof} <-
           security.build_signing_authority_acquisition_proof(
             agent_id,
             private_key,
             purpose: :coding_task_executor,
             owner: self()
           ),
         {:ok, opened_authority} <- security.open_signing_authority(proof) do
      case SigningAuthority.canonicalize(opened_authority) do
        {:ok, authority} ->
          {:ok, authority}

        {:error, reason} ->
          # A broker may have opened a live token before a malformed return
          # crossed this boundary. Always attempt public-facade cleanup before
          # reporting the canonicalization failure.
          _ = close_signing_authority(security, opened_authority)
          {:error, {:signing_authority_acquisition_failed, reason}}
      end
    else
      false -> {:error, :invalid_signing_key}
      {:error, :no_signing_key} -> {:error, :no_signing_key}
      {:error, reason} -> {:error, {:signing_authority_acquisition_failed, reason}}
      other -> {:error, {:signing_authority_acquisition_failed, other}}
    end
  rescue
    exception ->
      {:error, {:signing_authority_acquisition_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:signing_authority_acquisition_failed, {kind, reason}}}
  end

  defp close_signing_authority(security, authority) do
    case security.close_signing_authority(authority) do
      :ok -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected_close_result, other}}
    end
  rescue
    exception -> {:error, {:authority_close_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:authority_close_failed, {kind, reason}}}
  end

  # Validate the authority before dispatching to the runner. The public
  # Orchestrator facade repeats this check as part of its coarse gate; this
  # preflight ensures a signing failure cannot even enter an injected runner.
  defp validate_authority_signing(security, %SigningAuthority{} = authority) do
    case security.sign_with_authority(authority, "arbor://orchestrator/execute") do
      {:ok, _signed_request} -> :ok
      {:error, reason} -> {:error, {:signing_authority_sign_failed, reason}}
      other -> {:error, {:signing_authority_sign_failed, other}}
    end
  rescue
    exception -> {:error, {:signing_authority_sign_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:signing_authority_sign_failed, {kind, reason}}}
  end

  defp build_engine_opts(
         agent_id,
         %Plan{} = plan,
         %Compilation{} = compilation,
         exec_ctx,
         %SigningAuthority{} = authority,
         logs_root,
         pinned_action_bindings,
         pinned_handler_bindings
       ) do
    task_id = exec_ctx.task_id
    caller_id = Map.get(exec_ctx, :caller_id)
    timeout = effective_timeout(plan, Map.get(exec_ctx, :timeout))
    # Owner-derived interaction wait is the Engine approval timeout for compiled
    # coding DOT runs. Do not re-cap via coding_approval_timeout_ms/1 (legacy
    # 300_000ms default) — that path remains for CandidateVerifier and other
    # non-DOT consumers. Operator config may only shorten this value.
    interaction_wait_ms = Config.coding_interaction_wait_ms(timeout)

    with {:ok, validation_action_source_ms} <- validation_action_source_ms(compilation),
         {:ok, budget_allocation} <-
           BudgetPolicy.allocate(timeout, validation_action_source_ms) do
      dotted_budget_allocation =
        Map.new(budget_allocation, fn {key, value} ->
          {"coding_budget.#{key}", value}
        end)

      initial_values =
        compilation.initial_values
        |> Map.put("session.run_deadline_unix_ms", System.system_time(:millisecond) + timeout)
        |> Map.put("session.agent_id", agent_id)
        |> Map.put("session.task_id", task_id)
        |> maybe_put_session_caller_id(caller_id)
        |> maybe_put_session_metadata(Map.get(exec_ctx, :metadata))
        |> Map.merge(dotted_budget_allocation)
        # Owner-only human-wait cap; distinct from coding_budget.approval_ms reserve.
        |> Map.put("coding_budget.interaction_wait_ms", interaction_wait_ms)

      opts =
        [
          authorization: true,
          agent_id: agent_id,
          task_id: task_id,
          run_id: task_id,
          pipeline_id: task_id,
          signing_authority: authority,
          initial_values: initial_values,
          logs_root: logs_root,
          transcript_sink: {
            ArtifactStore,
            :append_transcript_turn,
            [logs_root, task_id]
          },
          design_artifact_sink: {
            ArtifactStore,
            :archive_design_artifact,
            [logs_root, task_id]
          },
          design_artifact_source: {
            ArtifactStore,
            :read_design_artifact,
            [logs_root, task_id]
          },
          graph_hash: compilation.graph_hash,
          execution_manifest: compilation.execution_manifest,
          execution_manifest_digest: compilation.execution_manifest_digest,
          pinned_action_bindings: pinned_action_bindings,
          pinned_handler_bindings: pinned_handler_bindings,
          workdir: plan.repo_root,
          timeout: timeout,
          approval_timeout_ms: interaction_wait_ms,
          spawning_pid: self(),
          resumable: true,
          cache: false
        ]

      # The authenticated caller remains distinct from the execution principal.
      # Engine middleware intersects both principals' scoped capabilities at
      # every node and action invocation.
      final_opts =
        case caller_id do
          cid when is_binary(cid) and cid != "" ->
            Keyword.put(opts, :caller_id, cid)

          _ ->
            opts
        end

      {:ok, final_opts}
    else
      _ -> {:error, :invalid_budget_policy_inputs}
    end
  end

  defp validation_action_source_ms(%Compilation{} = compilation) do
    compilation.initial_values
    |> Map.get("coding_plan_validation_program")
    |> ValidationProgram.largest_timeout_ms()
  end

  defp effective_timeout(%Plan{} = plan, context_timeout) do
    plan_timeout = plan.budgets["wall_clock_ms"]

    if is_integer(context_timeout) and context_timeout > 0,
      do: min(plan_timeout, context_timeout),
      else: plan_timeout
  end

  defp maybe_put_session_caller_id(values, caller_id)
       when is_binary(caller_id) and caller_id != "" do
    Map.put(values, "session.caller_id", caller_id)
  end

  defp maybe_put_session_caller_id(values, _), do: values

  # Metadata is data only — never promoted to engine control options.
  defp maybe_put_session_metadata(values, metadata) when is_map(metadata) do
    Map.put(values, "session.metadata", metadata)
  end

  defp maybe_put_session_metadata(values, _), do: values

  defp prepare_task_logs_root(task_id) do
    digest =
      :crypto.hash(:sha256, task_id)
      |> Base.encode16(case: :lower)

    with {:ok, base} <- canonical_logs_base(),
         {:ok, root} <- SafePath.safe_join(base, "task-" <> digest),
         :ok <- ensure_task_logs_directory(root),
         {:ok, canonical_root} <- verify_task_logs_directory(root, base) do
      {:ok, canonical_root}
    end
  end

  defp canonical_logs_base do
    configured = Config.coding_pipeline_logs_root()

    with :ok <- validate_logs_base_path(configured),
         :ok <- create_logs_base(configured),
         {:ok, canonical} <- SafePath.resolve_real(configured),
         true <- File.dir?(canonical) do
      {:ok, canonical}
    else
      _ -> {:error, :invalid_coding_pipeline_logs_root}
    end
  end

  defp validate_logs_base_path(path) when is_binary(path) do
    with :ok <- SafePath.validate(path),
         true <- SafePath.absolute?(path) do
      :ok
    else
      _ -> {:error, :invalid_path}
    end
  end

  defp validate_logs_base_path(_path), do: {:error, :invalid_path}

  defp create_logs_base(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp ensure_task_logs_directory(root) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, _stat} ->
        {:error, :unsafe_coding_task_logs_root}

      {:error, :enoent} ->
        create_task_logs_directory(root)

      {:error, _reason} ->
        {:error, :unsafe_coding_task_logs_root}
    end
  end

  defp create_task_logs_directory(root) do
    case File.mkdir(root) do
      :ok ->
        case File.chmod(root, 0o700) do
          :ok ->
            :ok

          {:error, _reason} ->
            File.rmdir(root)
            {:error, :unsafe_coding_task_logs_root}
        end

      {:error, :eexist} ->
        ensure_task_logs_directory(root)

      {:error, _reason} ->
        {:error, :unsafe_coding_task_logs_root}
    end
  end

  defp verify_task_logs_directory(root, base) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(root),
         {:ok, canonical_root} <- SafePath.resolve_real(root),
         true <- canonical_root == root,
         true <- contained_in?(base, canonical_root) do
      {:ok, canonical_root}
    else
      _ -> {:error, :unsafe_coding_task_logs_root}
    end
  end

  defp reconcile_action_uri_prefixes do
    with :ok <- Arbor.Actions.register_action_uri_prefixes(),
         prefixes when is_list(prefixes) and prefixes != [] <-
           Arbor.Actions.action_namespace_uri_prefixes(),
         true <- Enum.all?(prefixes, &Arbor.Security.uri_registered?/1) do
      :ok
    else
      _ -> {:error, :action_uri_prefix_reconciliation_failed}
    end
  rescue
    _ -> {:error, :action_uri_prefix_reconciliation_failed}
  catch
    _, _ -> {:error, :action_uri_prefix_reconciliation_failed}
  end

  defp invoke_runner(graph_path, opts) do
    runner = Config.coding_pipeline_runner()

    cond do
      not is_atom(runner) ->
        {:error, :coding_pipeline_runner_unavailable}

      not Code.ensure_loaded?(runner) ->
        {:error, :coding_pipeline_runner_unavailable}

      function_exported?(runner, :run_file_as, 4) ->
        principal = Keyword.fetch!(opts, :agent_id)
        authority = Keyword.fetch!(opts, :signing_authority)
        # run_file_as/4 performs the public facade's mixed-credential check and
        # installs the authority into the actual Engine opts. It must not see
        # the process-local credential in its caller-supplied opts.
        runner_opts = Keyword.delete(opts, :signing_authority)

        invoke_with_timeout(
          fn bounded_opts ->
            runner.run_file_as(graph_path, principal, authority, bounded_opts)
          end,
          runner_opts
        )

      true ->
        {:error, :coding_pipeline_runner_unavailable}
    end
  rescue
    e -> {:error, {:pipeline_run_error, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:pipeline_run_exit, reason}}
  end

  defp invoke_with_timeout(fun, opts) when is_function(fun, 1) do
    case Keyword.fetch(opts, :timeout) do
      :error ->
        fun.(opts)

      {:ok, timeout} ->
        # The link is intentional: TaskStore cancellation kills this owner,
        # which must also terminate the Engine process and its owned resources.
        task = Task.async(fn -> capture_runner_result(fn -> fun.(opts) end) end)

        case Task.yield(task, timeout) do
          {:ok, {:ok, result}} ->
            result

          {:ok, {:error, reason}} ->
            {:error, reason}

          {:exit, reason} ->
            {:error, {:pipeline_run_exit, reason}}

          nil ->
            _ = Task.shutdown(task, :brutal_kill)
            {:ok, synthesize_pipeline_timeout_result(opts, timeout)}
        end
    end
  end

  # The owned Engine task was killed before it could reach a terminal node, so
  # there is no real Engine result to adapt. Synthesizing a canonical
  # pipeline-error Engine-like result routes the timeout through the same
  # adapt_result/pipeline_error_detail path as every other pipeline_error,
  # instead of surfacing a raw {:error, {:pipeline_timeout, _}} that TaskStore
  # would collapse to the generic, evidence-free "task_runner_failed".
  defp synthesize_pipeline_timeout_result(opts, timeout) do
    task_id = Keyword.get(opts, :task_id)
    agent_id = Keyword.get(opts, :agent_id)

    %{
      context: %{
        "status" => "pipeline_error",
        "error" => "pipeline_timeout",
        "pipeline_timeout_ms" => timeout,
        "workspace_recovery" => workspace_recovery_locator(task_id, agent_id)
      }
    }
  end

  defp capture_runner_result(fun) do
    {:ok, fun.()}
  rescue
    e -> {:error, {:pipeline_run_error, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:pipeline_run_exit, reason}}
    kind, reason -> {:error, {:pipeline_run_throw, {kind, reason}}}
  end

  # ===========================================================================
  # Result adapter
  # ===========================================================================

  defp adapt_result(%{context: context} = engine_result, started_at, acp_agent, requested_model)
       when is_map(context) do
    adapt_engine_result(context, engine_result, started_at, acp_agent, requested_model)
  end

  defp adapt_result(
         %{"context" => context} = engine_result,
         started_at,
         acp_agent,
         requested_model
       )
       when is_map(context) do
    adapt_engine_result(context, engine_result, started_at, acp_agent, requested_model)
  end

  defp adapt_result({:ok, result}, started_at, acp_agent, requested_model),
    do: adapt_result(result, started_at, acp_agent, requested_model)

  defp adapt_result({:error, _} = error, _started_at, _acp_agent, _requested_model), do: error

  defp adapt_result(_other, _started_at, _acp_agent, _requested_model),
    do: {:error, :invalid_engine_result}

  defp adapt_engine_result(context, engine_result, started_at, acp_agent, requested_model) do
    with {:ok, payload} <-
           adapt_context(context, engine_result, acp_agent, requested_model) do
      wall_clock_ms = max(System.monotonic_time(:millisecond) - started_at, 0)

      {:ok,
       payload
       |> Map.put("acp_agent", acp_agent)
       |> Map.put("worker_provider", acp_agent)
       |> Map.put("metrics", build_pipeline_metrics(engine_result, context, wall_clock_ms))}
    end
  end

  defp adapt_context(context, engine_result, worker_provider, requested_model)
       when is_map(context) do
    clean = json_clean_map(context)
    status = context_get(clean, "status")
    legacy = context_get(clean, "legacy_status")

    cond do
      status in [nil, ""] ->
        {:error, :missing_terminal_status}

      status == "pipeline_error" ->
        {:error,
         {:pipeline_error,
          pipeline_error_detail(clean, engine_result, worker_provider, requested_model)}}

      not OutcomeMapper.terminal_status?(status) ->
        {:error, {:unknown_terminal_status, status}}

      true ->
        with {:ok, outcome} <-
               OutcomeMapper.map_terminal(
                 status,
                 clean,
                 requested_model: requested_model,
                 worker_provider: worker_provider
               ),
             {:ok, verification_report} <-
               adapt_terminal_verification(context, clean, status, legacy) do
          {:ok,
           clean
           |> build_coding_payload(status, legacy)
           |> Map.put("outcome", outcome)
           |> put_outcome_provider_session_id(outcome)
           |> maybe_put_verification_report(verification_report)
           |> maybe_put_validation_failure(engine_result)}
        else
          {:error, outcome} -> {:error, {:invalid_terminal_evidence, outcome}}
        end
    end
  end

  defp adapt_terminal_verification(raw_context, clean_context, status, legacy_status) do
    if terminal_validation_claimed?(raw_context, status) do
      {public_status, canonical_status} = terminal_status_pair(status, legacy_status)

      with {:ok, program} <-
             fetch_verification_evidence(clean_context, "coding_plan_validation_program"),
           {:ok, candidate_tree_oid} <-
             fetch_verification_evidence(clean_context, "validation_candidate_tree_oid"),
           {:ok, observed_at} <-
             fetch_verification_evidence(clean_context, "validation_observed_at"),
           {:ok, report} <-
             CandidateVerificationCore.verify(
               program,
               candidate_tree_oid,
               terminal_validation_evidence(clean_context),
               observed_at
             ),
           :ok <-
             validate_terminal_verification_consistency(
               public_status,
               canonical_status,
               report
             ) do
        {:ok, report}
      end
    else
      {:ok, nil}
    end
  end

  # The final checkpoint context is flat (`validation.passed`, `validation.exit_code`,
  # `validation.validated_tree_oid`, etc.) with no nested `validation` map — only the
  # public "validation" result projection already reconstructed it via
  # extract_prefixed_map/2. Terminal verification must use the same reconstruction so a
  # legitimate flat-evidence terminal doesn't fail adaptation for lack of a bare
  # "validation" key.
  defp terminal_validation_evidence(clean_context) do
    case Map.get(clean_context, "validation") do
      value when is_map(value) and not is_struct(value) ->
        value

      _other ->
        context_get(clean_context, "validation.result") ||
          extract_prefixed_map(clean_context, "validation.")
    end
  end

  defp terminal_validation_claimed?(context, status) do
    status in ~w(validation_failed validation_capacity_exceeded) or
      Enum.any?(~w(validation validation_candidate_tree_oid validation_observed_at), fn key ->
        is_map(context) and Map.has_key?(context, key)
      end)
  end

  defp fetch_verification_evidence(context, key) do
    case Map.fetch(context, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_verification_evidence, key}}
    end
  end

  defp validate_terminal_verification_consistency("validation_failed", _canonical_status, %{
         "status" => report_status
       })
       when report_status in ~w(failed blocked),
       do: :ok

  defp validate_terminal_verification_consistency(
         "validation_capacity_exceeded",
         "validation_capacity_exceeded",
         %{"status" => "blocked"}
       ),
       do: :ok

  defp validate_terminal_verification_consistency(
         _public_status,
         _canonical_status,
         %{"status" => "passed"}
       ),
       do: :ok

  defp validate_terminal_verification_consistency(_public_status, _canonical_status, _report),
    do: {:error, :verification_terminal_status_mismatch}

  defp maybe_put_verification_report(payload, nil), do: payload

  defp maybe_put_verification_report(payload, verification_report),
    do: Map.put(payload, "verification_report", verification_report)

  defp maybe_put_validation_failure(
         %{"canonical_status" => "validation_failed"} = payload,
         engine_result
       ) do
    case engine_result_field(engine_result, :node_failure_reasons, "node_failure_reasons") do
      %_{} ->
        payload

      reasons when is_map(reasons) ->
        case Map.fetch(reasons, "validate") do
          {:ok, reason} -> maybe_put_bounded_validation_failure(payload, reason)
          :error -> payload
        end

      _other ->
        payload
    end
  end

  defp maybe_put_validation_failure(payload, _engine_result), do: payload

  defp maybe_put_bounded_validation_failure(payload, reason) when is_binary(reason) do
    valid =
      byte_size(reason) in 1..@max_validation_failure_reason_bytes and String.valid?(reason)

    if valid do
      case RunLifecycleAdapter.bound_failure_reason(reason) do
        bounded when is_binary(bounded) and bounded != "" -> Map.put(payload, "error", bounded)
        _other -> payload
      end
    else
      payload
    end
  end

  defp maybe_put_bounded_validation_failure(payload, _reason), do: payload

  defp build_pipeline_metrics(engine_result, context, wall_clock_ms) do
    clean_context = json_clean_map(context)
    completed = completed_node_ids(engine_result)
    exposed_completed = Enum.take(completed, @max_metric_completed_nodes)
    {node_durations, durations_truncated?} = metric_node_durations(engine_result)

    close_usage = metric_context_value(clean_context, "close", "usage")
    last_message_usage = metric_context_value(clean_context, "worker_msg", "usage")

    usage =
      clean_metric_usage(close_usage) ||
        clean_metric_usage(last_message_usage)

    context_tokens =
      metric_non_negative_integer(metric_context_value(clean_context, "close", "context_tokens")) ||
        metric_non_negative_integer(
          metric_context_value(clean_context, "worker_msg", "context_tokens")
        ) ||
        usage_input_tokens(clean_metric_usage(last_message_usage))

    %{
      "execution_path" => "pipeline",
      "wall_clock_ms" => wall_clock_ms,
      "node_durations_ms" => node_durations,
      "completed_nodes" => exposed_completed,
      "completed_node_count" => length(completed),
      "validation_attempts" => Enum.count(completed, &(&1 == "validate")),
      "review_attempts" => Enum.count(completed, &(&1 == "review_change")),
      "protocol_retry_count" => metric_counter(clean_context, "protocol_retry_count"),
      "validation_rework_count" => metric_counter(clean_context, "validation_rework_count"),
      "review_rework_count" => metric_counter(clean_context, "review_rework_count"),
      "operator_rework_count" => metric_counter(clean_context, "operator_rework_count"),
      "total_rework_count" => metric_counter(clean_context, "total_rework_count")
    }
    |> maybe_put_metric(
      "completed_nodes_truncated",
      length(completed) > @max_metric_completed_nodes
    )
    |> maybe_put_metric("node_durations_truncated", durations_truncated?)
    |> maybe_put_metric("usage", usage)
    |> maybe_put_metric("context_tokens", context_tokens)
    |> maybe_put_metric(
      "worker_close_status",
      clean_metric_status(metric_context_value(clean_context, "close", "status"))
    )
    |> maybe_put_metric(
      "workspace_release_status",
      clean_metric_status(metric_context_value(clean_context, "release", "status"))
    )
    |> maybe_put_metric(
      "workspace_expires_at",
      workspace_release_expires_at(clean_context)
    )
  end

  defp completed_node_ids(engine_result) do
    case engine_result_field(engine_result, :completed_nodes, "completed_nodes") do
      nodes when is_list(nodes) ->
        nodes
        |> Enum.reduce([], fn node_id, acc ->
          case clean_metric_node_id(node_id) do
            nil -> acc
            clean -> [clean | acc]
          end
        end)
        |> Enum.reverse()

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp metric_node_durations(engine_result) do
    entries =
      case engine_result_field(engine_result, :node_durations, "node_durations") do
        %_{} ->
          []

        durations when is_map(durations) ->
          durations
          |> Enum.reduce([], fn {node_id, duration}, acc ->
            with {clean_id, rank} <- clean_metric_node_key(node_id),
                 true <- is_integer(duration) and duration >= 0 do
              [{clean_id, rank, duration} | acc]
            else
              _ -> acc
            end
          end)
          |> Enum.sort_by(fn {node_id, rank, duration} -> {node_id, rank, duration} end)
          |> Enum.uniq_by(fn {node_id, _rank, _duration} -> node_id end)

        _ ->
          []
      end

    selected = Enum.take(entries, @max_metric_node_durations)

    durations =
      Map.new(selected, fn {node_id, _rank, duration} ->
        {node_id, duration}
      end)

    {durations, length(entries) > @max_metric_node_durations}
  rescue
    _ -> {%{}, false}
  end

  defp engine_result_field(result, atom_key, string_key) when is_map(result) do
    case Map.fetch(result, atom_key) do
      {:ok, value} -> value
      :error -> Map.get(result, string_key)
    end
  end

  defp engine_result_field(_result, _atom_key, _string_key), do: nil

  defp clean_metric_node_id(node_id) do
    case clean_metric_node_key(node_id) do
      {clean, _rank} -> clean
      nil -> nil
    end
  end

  defp clean_metric_node_key(node_id) when is_binary(node_id) do
    if String.valid?(node_id) and node_id != "" and
         byte_size(node_id) <= @max_metric_node_id_bytes,
       do: {node_id, 0},
       else: nil
  end

  defp clean_metric_node_key(node_id) when is_atom(node_id) do
    case clean_metric_node_key(Atom.to_string(node_id)) do
      {clean, _rank} -> {clean, 1}
      nil -> nil
    end
  end

  defp clean_metric_node_key(_node_id), do: nil

  defp metric_context_value(context, prefix, key) do
    context_get(context, "#{prefix}.#{key}") ||
      nested_get(context_get(context, prefix), key)
  end

  defp metric_counter(context, key) do
    metric_non_negative_integer(context_get(context, key)) || 0
  end

  defp metric_non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp metric_non_negative_integer(value) when is_binary(value) and byte_size(value) <= 32 do
    if String.valid?(value) do
      case Integer.parse(value) do
        {parsed, ""} when parsed >= 0 -> parsed
        _ -> nil
      end
    end
  end

  defp metric_non_negative_integer(_value), do: nil

  defp usage_input_tokens(usage) when is_map(usage) do
    Enum.find_value(~w(input_tokens inputTokens prompt_tokens promptTokens), fn key ->
      metric_non_negative_integer(Map.get(usage, key))
    end)
  end

  defp usage_input_tokens(_usage), do: nil

  defp clean_metric_status(nil), do: nil

  defp clean_metric_status(value) when is_binary(value) do
    if String.valid?(value) and value != "" and byte_size(value) <= @max_metric_node_id_bytes,
      do: value,
      else: nil
  end

  defp clean_metric_status(value) when is_atom(value),
    do: clean_metric_status(Atom.to_string(value))

  defp clean_metric_status(_value), do: nil

  defp clean_metric_usage(%_{}), do: nil

  defp clean_metric_usage(usage) when is_map(usage) do
    with {:ok, clean} <- clean_metric_map(usage, 0),
         true <- map_size(clean) > 0,
         {:ok, encoded} <- Jason.encode(clean),
         true <- byte_size(encoded) <= @max_metric_usage_encoded_bytes do
      clean
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp clean_metric_usage(_usage), do: nil

  defp clean_metric_map(map, depth) when depth <= @max_metric_usage_depth do
    entries =
      map
      |> Enum.reduce([], fn {key, value}, acc ->
        with {clean_key, rank} <- clean_metric_key(key),
             {:ok, clean_value} <- clean_metric_value(value, depth + 1) do
          [{clean_key, rank, clean_value} | acc]
        else
          _ -> acc
        end
      end)
      |> Enum.sort_by(fn {key, rank, _value} -> {key, rank} end)
      |> Enum.uniq_by(fn {key, _rank, _value} -> key end)
      |> Enum.take(@max_metric_usage_entries)

    {:ok, Map.new(entries, fn {key, _rank, value} -> {key, value} end)}
  end

  defp clean_metric_map(_map, _depth), do: :drop

  defp clean_metric_key(key) when is_binary(key) do
    if String.valid?(key) and byte_size(key) <= @max_metric_usage_key_bytes,
      do: {key, 0},
      else: nil
  end

  defp clean_metric_key(key) when is_atom(key) do
    case clean_metric_key(Atom.to_string(key)) do
      {clean, _rank} -> {clean, 1}
      nil -> nil
    end
  end

  defp clean_metric_key(_key), do: nil

  defp clean_metric_value(_value, depth) when depth > @max_metric_usage_depth, do: :drop

  defp clean_metric_value(value, _depth)
       when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp clean_metric_value(value, _depth) when is_binary(value) do
    if String.valid?(value) and byte_size(value) <= @max_metric_usage_string_bytes,
      do: {:ok, value},
      else: :drop
  end

  defp clean_metric_value(value, depth) when is_atom(value) do
    clean_metric_value(Atom.to_string(value), depth)
  end

  defp clean_metric_value(%_{}, _depth), do: :drop
  defp clean_metric_value(map, depth) when is_map(map), do: clean_metric_map(map, depth)

  defp clean_metric_value(list, depth) when is_list(list) do
    clean =
      list
      |> Enum.take(@max_metric_usage_list_items)
      |> Enum.reduce([], fn value, acc ->
        case clean_metric_value(value, depth + 1) do
          {:ok, clean_value} -> [clean_value | acc]
          :drop -> acc
        end
      end)
      |> Enum.reverse()

    {:ok, clean}
  end

  defp clean_metric_value(_value, _depth), do: :drop

  defp maybe_put_metric(map, _key, nil), do: map
  defp maybe_put_metric(map, _key, false), do: map
  defp maybe_put_metric(map, key, value), do: Map.put(map, key, value)

  defp build_coding_payload(context, status, legacy) do
    {public_status, canonical_status} = terminal_status_pair(status, legacy)

    commit = context_get(context, "commit") || context_get(context, "commit_hash")
    commit_hash = context_get(context, "commit_hash") || commit
    review = extract_review(context)

    %{
      "status" => public_status,
      "canonical_status" => canonical_status,
      "branch" => context_get(context, "branch"),
      "branch_provenance" => metric_context_value(context, "workspace", "branch_provenance"),
      "base_commit" =>
        metric_context_value(context, "workspace", "base_commit") ||
          context_get(context, "base_ref"),
      "commit" => commit,
      "commit_hash" => commit_hash,
      "repo_path" => context_get(context, "repo_path"),
      "worktree_path" => context_get(context, "worktree_path"),
      "diff" => context_get(context, "diff"),
      "files" => context_get(context, "files"),
      "validation" => extract_validation(context),
      "review" => review,
      "review_recommendation" =>
        context_get(context, "review_recommendation") ||
          nested_get(review, "recommendation"),
      "tier_decision" =>
        context_get(context, "tier_decision") || nested_get(review, "tier_decision"),
      "human_required" =>
        context_get(context, "human_required") || nested_get(review, "human_required"),
      "security_veto" =>
        context_get(context, "security_veto") || nested_get(review, "security_veto"),
      "blast_radius" =>
        context_get(context, "blast_radius") || nested_get(review, "blast_radius"),
      "pr_url" => extract_pr_url(context),
      "workspace_id" => context_get(context, "workspace_id"),
      "evidence_ref" => metric_context_value(context, "release", "evidence_ref"),
      "published_commit" => metric_context_value(context, "release", "published_commit"),
      "branch_lifecycle" => metric_context_value(context, "release", "branch_lifecycle"),
      "worker_session_id" => context_get(context, "worker_session_id"),
      "worker_provider_session_id" => context_get(context, "worker_provider_session_id"),
      "response_text" => extract_response_text(context),
      "error" => context_get(context, "error") || context_get(context, "review_error"),
      # Operator approval fields are stable, bounded, JSON-clean scalars only —
      # never the raw interaction metadata map.
      "approval_request_id" => context_get(context, "approval_request_id"),
      "approval_note" => context_get(context, "approval_note")
    }
    |> Map.merge(workspace_release_projection(context))
    |> reject_nil_values()
  end

  defp terminal_status_pair("rework_exhausted", legacy_status) do
    if OutcomeMapper.terminal_status?(legacy_status),
      do: {legacy_status, "rework_exhausted"},
      else: {"rework_exhausted", "rework_exhausted"}
  end

  defp terminal_status_pair(status, _legacy_status), do: {status, status}

  defp pipeline_error_detail(context, engine_result, worker_provider, requested_model) do
    error_code = context_get(context, "error") || "pipeline_error"

    {:ok, outcome} =
      OutcomeMapper.map_pipeline_error(
        pipeline_error_outcome_code(error_code),
        context,
        requested_model: requested_model,
        worker_provider: worker_provider
      )

    %{
      "status" => "pipeline_error",
      "error" => error_code,
      "workspace_id" => context_get(context, "workspace_id"),
      "worker_provider" => worker_provider,
      "worker_session_id" => context_get(context, "worker_session_id"),
      "worker_provider_session_id" => outcome["provider_session_id"],
      "outcome" => outcome
    }
    |> Map.merge(workspace_release_projection(context))
    |> reject_nil_values()
    |> maybe_put_pipeline_failure_reason(error_code, engine_result)
    |> maybe_put_worker_provider_account_exhausted_reason(
      error_code,
      context
    )
    |> maybe_put_pipeline_timeout_evidence(error_code, context)
  end

  # A synthesized pipeline timeout is not a registered DOT pipeline_error
  # code (no graph node ever reported it), so it is mapped to the generic,
  # already-registered "pipeline_error" outcome (retryable in a new session)
  # rather than falling through OutcomeMapper's unregistered-code fallback,
  # which is meant for malformed evidence and marks retry "none".
  defp pipeline_error_outcome_code("pipeline_timeout"), do: "pipeline_error"
  defp pipeline_error_outcome_code(error_code), do: error_code

  defp put_outcome_provider_session_id(payload, %{"provider_session_id" => session_id})
       when is_binary(session_id) and session_id != "" do
    Map.put(payload, "worker_provider_session_id", session_id)
  end

  defp put_outcome_provider_session_id(payload, _outcome), do: payload

  defp maybe_put_pipeline_timeout_evidence(detail, "pipeline_timeout", context) do
    detail
    |> maybe_put_pipeline_timeout_ms(context)
    |> maybe_put_workspace_recovery(context)
  end

  defp maybe_put_pipeline_timeout_evidence(detail, _error_code, _context), do: detail

  defp maybe_put_pipeline_timeout_ms(detail, context) do
    case context_get(context, "pipeline_timeout_ms") do
      ms when is_integer(ms) and ms > 0 -> Map.put(detail, "pipeline_timeout_ms", ms)
      _other -> detail
    end
  end

  defp maybe_put_workspace_recovery(detail, context) do
    case context_get(context, "workspace_recovery") do
      recovery when is_map(recovery) and not is_struct(recovery) and map_size(recovery) > 0 ->
        Map.put(detail, "workspace_recovery", recovery)

      _other ->
        detail
    end
  end

  defp maybe_put_pipeline_failure_reason(detail, "pipeline_error", engine_result) do
    with reasons when is_map(reasons) and not is_struct(reasons) <-
           engine_result_field(engine_result, :node_failure_reasons, "node_failure_reasons"),
         reason when is_binary(reason) <-
           Enum.find_value(@generic_pipeline_failure_nodes, &Map.get(reasons, &1)) do
      put_bounded_pipeline_failure_reason(detail, reason)
    else
      _other -> detail
    end
  end

  defp maybe_put_pipeline_failure_reason(detail, error_code, engine_result) do
    with node_id when is_binary(node_id) <- Map.get(@pipeline_error_failure_nodes, error_code),
         reasons when is_map(reasons) and not is_struct(reasons) <-
           engine_result_field(engine_result, :node_failure_reasons, "node_failure_reasons"),
         reason when is_binary(reason) <- Map.get(reasons, node_id) do
      put_bounded_pipeline_failure_reason(detail, reason)
    else
      _other -> detail
    end
  end

  defp put_bounded_pipeline_failure_reason(detail, reason) do
    valid =
      byte_size(reason) in 1..@max_pipeline_failure_reason_bytes and String.valid?(reason)

    if valid do
      case RunLifecycleAdapter.bound_failure_reason(reason) do
        bounded when is_binary(bounded) and bounded != "" ->
          Map.put(detail, "failure_reason", bounded)

        _other ->
          detail
      end
    else
      detail
    end
  end

  defp maybe_put_worker_provider_account_exhausted_reason(
         detail,
         "worker_provider_account_exhausted",
         context
       ) do
    reason = context_get(context, "worker_failure_reason")

    if is_binary(reason) and byte_size(reason) in 1..@max_pipeline_failure_reason_bytes and
         String.valid?(reason) and String.trim(reason) != "" do
      case RunLifecycleAdapter.bound_failure_reason(reason) do
        bounded when is_binary(bounded) and bounded != "" ->
          Map.put(detail, "failure_reason", bounded)

        _other ->
          detail
      end
    else
      detail
    end
  end

  defp maybe_put_worker_provider_account_exhausted_reason(detail, _error_code, _context),
    do: detail

  defp attach_workspace_release_artifact(artifacts, result) do
    case Map.take(result, ["workspace_release_status", "workspace_expires_at"]) do
      release when map_size(release) == 0 ->
        artifacts

      release ->
        case WorkspaceReleaseDescriptor.normalize(release) do
          {:ok, descriptor} ->
            artifacts
            |> Map.put("workspace_release", descriptor)
            |> attach_branch_lifecycle_artifact(result)

          {:error, _reason} ->
            artifacts
        end
    end
  end

  defp attach_branch_lifecycle_artifact(artifacts, result) do
    case Map.get(result, "branch_lifecycle") do
      lifecycle when is_map(lifecycle) ->
        case BranchLifecycleDescriptor.normalize(lifecycle) do
          {:ok, descriptor} -> Map.put(artifacts, "branch_lifecycle", descriptor)
          {:error, _reason} -> artifacts
        end

      _ ->
        artifacts
    end
  end

  # Public results expose only the descriptor read back through the owning
  # ArtifactStore surface, never action context or inline turn content.
  defp attach_transcript_artifact(artifacts, logs_root, task_id, engine_result)
       when is_map(artifacts) do
    expected = expected_transcript_descriptor(engine_result)

    case ArtifactStore.transcript_descriptor(logs_root, task_id) do
      {:ok, descriptor} when is_nil(expected) or descriptor == expected ->
        {:ok, Map.put(artifacts, "acp_transcript", descriptor)}

      {:ok, _descriptor} ->
        {:error, :transcript_artifact_descriptor_mismatch}

      {:error, :absent} when is_map(expected) ->
        {:error, :transcript_artifact_missing}

      {:error, :absent} ->
        {:ok, artifacts}

      {:error, reason} ->
        {:error, {:transcript_artifact_unavailable, reason}}
    end
  end

  defp attach_transcript_artifact(_artifacts, _logs_root, _task_id, _engine_result),
    do: {:error, :invalid_transcript_artifacts}

  # The action result descriptor is already bounded checkpoint data. Matching
  # it to the final store read catches deletion or replacement across resume.
  defp expected_transcript_descriptor(engine_result) do
    case engine_result_field(engine_result, :context, "context") do
      context when is_map(context) ->
        Enum.reduce(context, nil, fn
          {key, value}, best when is_binary(key) and is_map(value) ->
            if String.ends_with?(key, ".transcript") do
              choose_latest_transcript_descriptor(best, value)
            else
              best
            end

          _entry, best ->
            best
        end)

      _other ->
        nil
    end
  end

  defp choose_latest_transcript_descriptor(best, candidate) do
    case TranscriptDescriptor.normalize(candidate) do
      {:ok, normalized} ->
        if is_nil(best) or normalized["turns_seen"] > best["turns_seen"],
          do: normalized,
          else: best

      {:error, _reason} ->
        best
    end
  end

  defp workspace_release_projection(context) do
    status = workspace_release_status(context_get(context, "release.status"))

    %{}
    |> maybe_put_metric("workspace_release_status", status)
    |> maybe_put_metric("workspace_expires_at", workspace_release_expires_at(context, status))
    |> maybe_put_branch_lifecycle(context)
  end

  defp maybe_put_branch_lifecycle(map, context) do
    case BranchLifecycleDescriptor.normalize(
           metric_context_value(context, "release", "branch_lifecycle")
         ) do
      {:ok, descriptor} -> Map.put(map, "branch_lifecycle", descriptor)
      _ -> map
    end
  end

  defp workspace_release_expires_at(context) do
    workspace_release_expires_at(
      context,
      clean_metric_status(metric_context_value(context, "release", "status"))
    )
  end

  defp workspace_release_expires_at(context, "retained") do
    case metric_context_value(context, "release", "expires_at") do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, expires_at, _offset} -> DateTime.to_iso8601(expires_at)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp workspace_release_expires_at(_context, _status), do: nil

  defp workspace_release_status(status)
       when status in ["retained", "removed", "discarded", "discard_pending"],
       do: status

  defp workspace_release_status(status)
       when status in [:retained, :removed, :discarded, :discard_pending],
       do: Atom.to_string(status)

  defp workspace_release_status(_status), do: nil

  defp extract_review(context) do
    cond do
      is_map(context_get(context, "review")) ->
        case json_clean_map(context_get(context, "review")) do
          cleaned when map_size(cleaned) > 0 -> cleaned
          _ -> nil
        end

      true ->
        review_keys =
          context
          |> Enum.filter(fn {k, _} ->
            is_binary(k) and String.starts_with?(k, "review.")
          end)

        if review_keys == [] do
          nil
        else
          review_keys
          |> Enum.reduce(%{}, fn {k, v}, acc ->
            suffix = String.replace_prefix(k, "review.", "")
            Map.put(acc, suffix, v)
          end)
          |> json_clean_map()
          |> case do
            cleaned when map_size(cleaned) > 0 -> cleaned
            _ -> nil
          end
        end
    end
  end

  defp extract_validation(context) do
    value =
      context_get(context, "validation") ||
        context_get(context, "validation.result") ||
        extract_prefixed_map(context, "validation.")

    case json_clean_value(value) do
      :drop -> nil
      nil -> nil
      validation when is_map(validation) -> [validation]
      validations when is_list(validations) -> validations
      _ -> nil
    end
  end

  defp extract_response_text(context) do
    context_get(context, "response_text") ||
      context_get(context, "worker_msg.text") ||
      nested_get(context_get(context, "worker_msg"), "text")
  end

  defp extract_prefixed_map(context, prefix) do
    values =
      Enum.reduce(context, %{}, fn
        {key, value}, acc when is_binary(key) ->
          if String.starts_with?(key, prefix) do
            Map.put(acc, String.replace_prefix(key, prefix, ""), value)
          else
            acc
          end

        _, acc ->
          acc
      end)

    if map_size(values) == 0, do: nil, else: values
  end

  defp extract_pr_url(context) do
    context_get(context, "pr_url") ||
      context_get(context, "pr.url") ||
      nested_get(context_get(context, "pr"), "url")
  end

  defp nested_get(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key)
  end

  defp nested_get(_map, _key), do: nil

  # ===========================================================================
  # Workspace recovery lookup (pipeline timeout evidence only)
  # ===========================================================================

  # A pipeline timeout kills the owned Engine task before it can report
  # workspace state, so evidence must come from the public reconciliation
  # resource facade using only the exact task_id/principal_id this executor
  # already owns. The lookup is best-effort and always bounded: a missing
  # facade, an unmatched task/principal, or any exception yields a
  # deterministic locator instead of raising or fabricating a path.
  defp workspace_recovery_locator(task_id, agent_id)
       when is_binary(task_id) and is_binary(agent_id) do
    facade = Config.coding_reconciliation_resource_facade()

    if is_atom(facade) and Code.ensure_loaded?(facade) and
         function_exported?(facade, :coding_resource_inventory, 1) do
      lookup_workspace_recovery_resource(facade, task_id, agent_id)
    else
      pending_workspace_recovery_locator(task_id, agent_id, "unavailable")
    end
  rescue
    _exception -> pending_workspace_recovery_locator(task_id, agent_id, "unavailable")
  catch
    _kind, _reason -> pending_workspace_recovery_locator(task_id, agent_id, "unavailable")
  end

  defp workspace_recovery_locator(task_id, agent_id) do
    pending_workspace_recovery_locator(task_id, agent_id, "unavailable")
  end

  defp lookup_workspace_recovery_resource(facade, task_id, agent_id) do
    opts = [task_id: task_id, principal_id: agent_id, max_items: @max_workspace_recovery_items]

    case apply(facade, :coding_resource_inventory, [opts]) do
      {:ok, inventory} when is_map(inventory) and not is_struct(inventory) ->
        case select_workspace_recovery_resource(inventory, task_id, agent_id) do
          {:ok, resource} -> matched_workspace_recovery_locator(task_id, agent_id, resource)
          :not_found -> pending_workspace_recovery_locator(task_id, agent_id, "not_found")
        end

      _other ->
        pending_workspace_recovery_locator(task_id, agent_id, "unavailable")
    end
  rescue
    _exception -> pending_workspace_recovery_locator(task_id, agent_id, "unavailable")
  catch
    _kind, _reason -> pending_workspace_recovery_locator(task_id, agent_id, "unavailable")
  end

  defp select_workspace_recovery_resource(inventory, task_id, agent_id) do
    resources = Map.get(inventory, "resources")

    candidates =
      if is_list(resources) do
        Enum.filter(resources, fn resource ->
          is_map(resource) and not is_struct(resource) and
            Map.get(resource, "task_id") == task_id and
            Map.get(resource, "principal_id") == agent_id and
            Map.get(resource, "resource_type") in @workspace_recovery_resource_types
        end)
      else
        []
      end

    case Enum.sort_by(candidates, &workspace_recovery_priority/1) do
      [best | _rest] -> {:ok, best}
      [] -> :not_found
    end
  end

  defp workspace_recovery_priority(%{"resource_type" => "retained_workspace_record"}), do: 0
  defp workspace_recovery_priority(_resource), do: 1

  defp matched_workspace_recovery_locator(task_id, agent_id, resource) do
    %{
      "lookup_status" => "matched",
      "task_id" => task_id,
      "principal_id" => agent_id,
      "workspace_id" => bounded_recovery_string(Map.get(resource, "workspace_id")),
      "resource_type" => bounded_recovery_string(Map.get(resource, "resource_type")),
      "lifecycle" => bounded_recovery_string(Map.get(resource, "lifecycle")),
      "branch" => bounded_recovery_string(Map.get(resource, "branch")),
      "repo_path" => bounded_recovery_string(Map.get(resource, "repo_path")),
      "worktree_path" => bounded_recovery_string(Map.get(resource, "worktree_path")),
      "base_commit" => bounded_recovery_string(Map.get(resource, "base_commit")),
      "candidate_commit" => bounded_recovery_string(Map.get(resource, "candidate_commit")),
      "expires_at" => bounded_recovery_string(Map.get(resource, "expires_at"))
    }
    |> reject_nil_values()
  end

  defp pending_workspace_recovery_locator(task_id, agent_id, lookup_status) do
    %{
      "lookup_status" => lookup_status,
      "task_id" => task_id,
      "principal_id" => agent_id
    }
  end

  # Bounded to the same limit TaskTerminalEnvelope enforces on evidence
  # strings so an oversized value is omitted here, never silently truncated
  # downstream into an unusable path or identifier.
  defp bounded_recovery_string(value) when is_binary(value) do
    if String.valid?(value) and byte_size(value) > 0 and
         byte_size(value) <= @max_workspace_recovery_string_bytes and
         not String.contains?(value, <<0>>) do
      value
    else
      nil
    end
  end

  defp bounded_recovery_string(_value), do: nil

  # ===========================================================================
  # Progress / cancel helpers
  # ===========================================================================

  defp progress_from_entry(entry) do
    current_step =
      cond do
        is_binary(Map.get(entry, :current_node)) and Map.get(entry, :current_node) != "" ->
          Map.get(entry, :current_node)

        is_binary(Map.get(entry, "current_node")) and Map.get(entry, "current_node") != "" ->
          Map.get(entry, "current_node")

        is_atom(Map.get(entry, :status)) ->
          Atom.to_string(Map.get(entry, :status))

        is_binary(Map.get(entry, :status)) ->
          Map.get(entry, :status)

        is_binary(Map.get(entry, "status")) ->
          Map.get(entry, "status")

        true ->
          nil
      end

    waiting_on =
      cond do
        is_binary(Map.get(entry, :waiting_on)) -> Map.get(entry, :waiting_on)
        is_binary(Map.get(entry, "waiting_on")) -> Map.get(entry, "waiting_on")
        Map.get(entry, :status) == :suspended -> "suspended"
        Map.get(entry, "status") == "suspended" -> "suspended"
        true -> nil
      end

    %{"current_step" => current_step, "waiting_on" => waiting_on}
  end

  # ===========================================================================
  # JSON cleanliness helpers (result adaptation only)
  # ===========================================================================

  defp context_get(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key)
  end

  # Clean engine context maps for TaskStore. Non-JSON leaves cause the entire
  # affected value to drop (never the atom/string "drop" inside lists/maps).
  defp json_clean_map(map) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn {k, v}, acc ->
      key =
        cond do
          is_binary(k) -> k
          is_atom(k) -> Atom.to_string(k)
          true -> nil
        end

      cleaned = json_clean_value(v)

      if is_binary(key) and cleaned != :drop do
        Map.put(acc, key, cleaned)
      else
        acc
      end
    end)
  end

  defp json_clean_value(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v

  defp json_clean_value(v) when is_atom(v), do: Atom.to_string(v)

  defp json_clean_value(list) when is_list(list) do
    # Non-empty keyword lists are atom-keyed — not JSON. Drop the field.
    if Keyword.keyword?(list) and list != [] do
      :drop
    else
      cleaned = Enum.map(list, &json_clean_value/1)

      # Any nested rich value (pid/fun/ref/struct) drops the entire list so
      # :drop never leaks as the atom/string "drop" into the payload.
      if Enum.any?(cleaned, &(&1 == :drop)) do
        :drop
      else
        cleaned
      end
    end
  end

  defp json_clean_value(%_{} = struct) do
    # Never leak structs (RunState, Outcome, etc.) — drop the field.
    _ = struct
    :drop
  end

  defp json_clean_value(map) when is_map(map), do: json_clean_map(map)

  defp json_clean_value(v)
       when is_pid(v) or is_function(v) or is_reference(v) or is_port(v) or is_tuple(v),
       do: :drop

  defp json_clean_value(_), do: :drop

  defp reject_nil_values(map) when is_map(map) do
    Map.reject(map, fn {_k, v} -> is_nil(v) end)
  end
end
