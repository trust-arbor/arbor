defmodule Arbor.Orchestrator.CodingPlan.ArtifactStore do
  @moduledoc """
  Archives the immutable inputs and output of coding-plan compilation.

  The caller supplies the per-task artifact root for compilation, terminal,
  design, transcript, adoption, and reconciliation artifacts. Artifact names
  are fixed here and never incorporate plan or task text. A private, mode-`0600`
  compilation seal claims one bundle identity through an exclusive hard link
  before the individual files are published through the same no-clobber pattern.

  The seal provides first-writer-wins immutability among callers using this API.
  It is not an OS-level defense against a same-user process deleting or replacing
  the entire artifact root or seal.

  CrossApp static-stage receipts use a store-owned filename under the hashed
  per-task root derived from `base_root` plus the exact task id. Callers never
  select the filename or destination path. Publication is API-level first-writer
  / no-clobber among callers of this API, not an OS guarantee against a malicious
  same-UID process that can unlink, chmod, or replace the task root or file.
  Receipt envelopes are JSON-clean and token-free.
  """

  @plan_filename "coding-plan.json"
  @pipeline_filename "coding-pipeline.dot"
  @manifest_filename "coding-compile-manifest.json"
  @compilation_seal_filename ".coding-compilation-seal.json"
  @compilation_seal_schema_version 1
  @compilation_artifact_filenames [
    @plan_filename,
    @pipeline_filename,
    @manifest_filename
  ]
  @terminal_evidence_filename "coding-terminal-evidence.json"
  @archived_terminal_required_keys MapSet.new(~w(
    schema_version
    task_id
    terminal_status
    canonical_status
    outcome
    compiled_workflow
    steering_history
    validation_outputs
    review_verdict
  ))
  @archived_terminal_optional_keys MapSet.new(~w(
    workspace_release
    branch_lifecycle
    verification_report
    candidate
    metrics
  ))
  @max_archived_node_durations 256
  @archived_metrics_keys MapSet.new(~w(
    execution_path
    wall_clock_ms
    node_durations_ms
    completed_nodes
    completed_node_count
    validation_attempts
    review_attempts
    protocol_retry_count
    design_rework_count
    validation_rework_count
    review_rework_count
    operator_rework_count
    total_rework_count
    completed_nodes_truncated
    node_durations_truncated
    usage
    context_tokens
    worker_close_status
    workspace_release_status
    workspace_expires_at
  ))
  @compiled_workflow_keys MapSet.new(~w(
    coding_plan_path
    coding_pipeline_path
    compile_manifest_path
    graph_hash
    compiler_version
  ))
  @task_terminal_filename "coding-task-terminal.json"
  @run_binding_filename "coding-run-binding.json"
  @engine_terminal_filename "coding-engine-terminal.json"
  @adapter_input_filename "coding-adapter-input.json"
  @terminal_decision_filename "coding-terminal-decision.json"
  @adoption_evidence_prefix "coding-adoption-evidence-"
  @reconciliation_directory "coding-reconciliation"
  @max_reconciliation_bytes 1_048_576
  @max_terminal_evidence_bytes 1_048_576
  @max_terminal_task_id_bytes 512
  @max_compilation_artifact_bytes 4_194_304
  @max_compilation_seal_bytes 4_096
  @max_run_binding_bytes 16_384
  @max_engine_terminal_bytes 65_536
  @max_adapter_input_bytes 1_048_576
  @max_terminal_decision_bytes 16_384
  @max_task_terminal_bytes 1_048_576
  @compilation_publication_barrier_key {__MODULE__, :compilation_publication_barrier}
  @static_receipt_filename "coding-cross-app-continuation-static-receipt.json"
  @static_receipt_publication_barrier_key {__MODULE__, :static_receipt_publication_barrier}
  @bounded_read_pre_open_hook_key {__MODULE__, :bounded_read_pre_open_hook}
  @engine_static_receipt_directory "coding-cross-app-static-receipts"
  @engine_static_receipt_generation_limit 8
  @digest_filename_regex ~r/\A[0-9a-f]{64}\.json\z/

  @terminal_result_keys MapSet.new(~w(
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
    branch_lifecycle
    artifacts
  ))

  alias Arbor.Actions
  alias Arbor.Common.SafePath

  alias Arbor.Contracts.Coding.{
    BranchLifecycleDescriptor,
    DesignArtifactDescriptor,
    ReconciliationManifest,
    TaskEvidenceDescriptor,
    VerificationReport,
    WorkspaceReleaseDescriptor
  }

  alias Arbor.Orchestrator.CodingPlan.CodingRunRecoveryCore
  alias Arbor.Orchestrator.CodingPlan.OutcomeMapper
  alias Arbor.Orchestrator.CodingPlan.TaskTerminalArchiveCore
  alias Arbor.Orchestrator.CodingPlan.TranscriptStore
  alias Arbor.Orchestrator.CodingPlan.ValidationCapacityTerminal

  @typedoc "JSON-clean descriptor for an archived coding-plan compilation."
  @type descriptor :: %{required(String.t()) => String.t()}

  @doc """
  Archives a normalized plan, exact generated DOT bytes, and compile manifest.

  The plan and manifest must be plain, string-keyed JSON objects. The manifest
  must contain non-empty `graph_hash` and `compiler_version` strings.
  """
  @spec archive(String.t(), map(), binary(), map()) ::
          {:ok, descriptor()} | {:error, term()}
  def archive(root, plan, dot_source, manifest) do
    with {:ok, root} <- normalize_root(root),
         :ok <- validate_json_object(plan, :invalid_plan),
         :ok <- validate_dot_source(dot_source),
         :ok <- validate_json_object(manifest, :invalid_manifest),
         {:ok, graph_hash} <- fetch_manifest_string(manifest, "graph_hash"),
         {:ok, compiler_version} <- fetch_manifest_string(manifest, "compiler_version"),
         :ok <- validate_compilation_graph_hash(graph_hash, dot_source),
         {:ok, plan_json} <- encode_json(plan, :plan),
         {:ok, manifest_json} <- encode_json(manifest, :manifest),
         paths = artifact_paths(root),
         artifacts = compilation_artifacts(paths, plan_json, dot_source, manifest_json),
         :ok <- validate_compilation_artifact_sizes(artifacts),
         :ok <- create_root(root),
         {:ok, seal_json} <- build_compilation_seal(artifacts),
         :ok <- publish_compilation_bundle(root, artifacts, seal_json) do
      {:ok,
       %{
         "coding_plan_path" => paths.coding_plan,
         "coding_pipeline_path" => paths.coding_pipeline,
         "compile_manifest_path" => paths.compile_manifest,
         "graph_hash" => graph_hash,
         "compiler_version" => compiler_version
       }}
    end
  end

  @doc """
  Publish the closed non-secret coding-run binding. First-writer exclusive.
  """
  @spec archive_run_binding(String.t(), map()) :: :ok | {:error, term()}
  def archive_run_binding(root, binding) when is_map(binding) do
    with {:ok, root} <- normalize_existing_root(root),
         :ok <- CodingRunRecoveryCore.closed_binding?(binding),
         {:ok, encoded} <- encode_canonical_json(binding, :run_binding),
         :ok <- validate_encoded_size(encoded, @max_run_binding_bytes),
         path = Path.join(root, @run_binding_filename),
         :ok <- validate_task_terminal_path(root, path) do
      write_closed_artifact_once(path, encoded, root, :run_binding)
    end
  rescue
    _ -> {:error, :run_binding_archive_error}
  catch
    _, _ -> {:error, :run_binding_archive_error}
  end

  def archive_run_binding(_root, _binding), do: {:error, :invalid_binding}

  @doc """
  Read a closed coding-run binding from an already-canonical task root.
  """
  @spec read_run_binding(String.t()) ::
          {:ok, map()} | {:error, :not_found | :malformed | :unavailable}
  def read_run_binding(root) when is_binary(root) do
    read_closed_artifact(root, @run_binding_filename, &CodingRunRecoveryCore.closed_binding?/1)
  end

  def read_run_binding(_), do: {:error, :unavailable}

  @doc """
  Publish the closed Engine-terminal receipt. First-writer exclusive; equal
  digest is idempotent, unequal digest is stale/duplicate.
  """
  @spec archive_engine_terminal(String.t(), map()) :: :ok | {:error, term()}
  def archive_engine_terminal(root, receipt) when is_map(receipt) do
    with {:ok, root} <- normalize_existing_root(root),
         :ok <- CodingRunRecoveryCore.closed_receipt?(receipt),
         {:ok, encoded} <- encode_canonical_json(receipt, :engine_terminal),
         :ok <- validate_encoded_size(encoded, @max_engine_terminal_bytes),
         path = Path.join(root, @engine_terminal_filename),
         :ok <- validate_task_terminal_path(root, path) do
      write_closed_artifact_once(path, encoded, root, :engine_terminal)
    end
  rescue
    _ -> {:error, :engine_terminal_archive_error}
  catch
    _, _ -> {:error, :engine_terminal_archive_error}
  end

  def archive_engine_terminal(_root, _receipt), do: {:error, :invalid_receipt}

  @doc "Read a closed Engine-terminal receipt from a canonical task root."
  @spec read_engine_terminal(String.t()) ::
          {:ok, map()} | {:error, :not_found | :malformed | :unavailable}
  def read_engine_terminal(root) when is_binary(root) do
    read_closed_artifact(
      root,
      @engine_terminal_filename,
      &CodingRunRecoveryCore.closed_receipt?/1
    )
  end

  def read_engine_terminal(_), do: {:error, :unavailable}

  @doc """
  Publish the closed CandidateVerificationCore adapter-input four-tuple.
  First-writer exclusive; equal bytes are idempotent.
  """
  @spec archive_adapter_input(String.t(), map()) :: :ok | {:error, term()}
  def archive_adapter_input(root, adapter) when is_map(adapter) do
    with {:ok, root} <- normalize_existing_root(root),
         :ok <- CodingRunRecoveryCore.closed_adapter_input?(adapter),
         {:ok, encoded} <- encode_canonical_json(adapter, :adapter_input),
         :ok <- validate_encoded_size(encoded, @max_adapter_input_bytes),
         path = Path.join(root, @adapter_input_filename),
         :ok <- validate_task_terminal_path(root, path) do
      write_closed_artifact_once(path, encoded, root, :adapter_input)
    end
  rescue
    _ -> {:error, :adapter_input_archive_error}
  catch
    _, _ -> {:error, :adapter_input_archive_error}
  end

  def archive_adapter_input(_root, _adapter), do: {:error, :invalid_adapter_input}

  @doc "Read a closed adapter-input artifact from a canonical task root."
  @spec read_adapter_input(String.t()) ::
          {:ok, map()} | {:error, :not_found | :malformed | :unavailable}
  def read_adapter_input(root) when is_binary(root) do
    read_closed_artifact(
      root,
      @adapter_input_filename,
      &CodingRunRecoveryCore.closed_adapter_input?/1
    )
  end

  def read_adapter_input(_), do: {:error, :unavailable}

  @doc """
  Publish the closed terminal-decision descriptor. First-writer exclusive.
  """
  @spec archive_terminal_decision(String.t(), map()) :: :ok | {:error, term()}
  def archive_terminal_decision(root, decision) when is_map(decision) do
    with {:ok, root} <- normalize_existing_root(root),
         :ok <- CodingRunRecoveryCore.closed_decision?(decision),
         {:ok, encoded} <- encode_canonical_json(decision, :terminal_decision),
         :ok <- validate_encoded_size(encoded, @max_terminal_decision_bytes),
         path = Path.join(root, @terminal_decision_filename),
         :ok <- validate_task_terminal_path(root, path) do
      write_closed_artifact_once(path, encoded, root, :terminal_decision)
    end
  rescue
    _ -> {:error, :terminal_decision_archive_error}
  catch
    _, _ -> {:error, :terminal_decision_archive_error}
  end

  def archive_terminal_decision(_root, _decision), do: {:error, :invalid_decision}

  @doc "Read a closed terminal-decision artifact from a canonical task root."
  @spec read_terminal_decision(String.t()) ::
          {:ok, map()} | {:error, :not_found | :malformed | :unavailable}
  def read_terminal_decision(root) when is_binary(root) do
    read_closed_artifact(
      root,
      @terminal_decision_filename,
      &CodingRunRecoveryCore.closed_decision?/1
    )
  end

  def read_terminal_decision(_), do: {:error, :unavailable}

  @doc """
  Read a matching `coding-task-terminal.json` archive from a canonical task root.
  """
  @spec read_task_terminal(String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :malformed | :unavailable}
  def read_task_terminal(root, task_id)
      when is_binary(root) and is_binary(task_id) do
    with {:ok, root} <- normalize_existing_root(root),
         :ok <- validate_terminal_task_id(task_id),
         path = Path.join(root, @task_terminal_filename),
         :ok <- validate_task_terminal_path(root, path) do
      case read_descriptor_bounded_file(path, @max_task_terminal_bytes) do
        {:ok, encoded} ->
          decode_task_terminal_archive(encoded, task_id)

        {:error, :enoent} ->
          {:error, :not_found}

        {:error, :eio} ->
          {:error, :unavailable}

        {:error, :malformed} ->
          {:error, :malformed}

        {:error, _} ->
          {:error, :unavailable}
      end
    else
      {:error, :eio} -> {:error, :unavailable}
      {:error, {:invalid_terminal_task_id, _}} -> {:error, :malformed}
      {:error, _} -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  def read_task_terminal(_, _), do: {:error, :unavailable}

  @doc """
  Read the fixed compilation artifacts for one task-derived archive root.

  The task id is hashed before it is used as a path segment. Every artifact
  must be a mode-`0600` regular file beneath the canonical task root, and the
  archived DOT bytes must match the manifest graph hash.
  """
  @spec read_task_compilation(String.t(), String.t()) ::
          {:ok, map()}
          | {:error, :coding_compilation_provenance_unavailable | :eio | :unavailable}
  def read_task_compilation(base_root, task_id) do
    with :ok <- validate_terminal_task_id(task_id),
         {:ok, base_root} <- normalize_compilation_base(base_root),
         {:ok, task_root} <- compilation_task_root(base_root, task_id),
         paths = artifact_paths(task_root),
         {:ok, seal_json} <-
           read_compilation_file(
             compilation_seal_path(task_root),
             task_root,
             @max_compilation_seal_bytes
           ),
         {:ok, seal} <- decode_compilation_seal(seal_json),
         {:ok, plan_json} <-
           read_compilation_file(
             paths.coding_plan,
             task_root,
             @max_compilation_artifact_bytes
           ),
         {:ok, dot_source} <-
           read_compilation_file(
             paths.coding_pipeline,
             task_root,
             @max_compilation_artifact_bytes
           ),
         {:ok, manifest_json} <-
           read_compilation_file(
             paths.compile_manifest,
             task_root,
             @max_compilation_artifact_bytes
           ),
         :ok <- verify_sealed_compilation_artifact(seal, @plan_filename, plan_json),
         :ok <- verify_sealed_compilation_artifact(seal, @pipeline_filename, dot_source),
         :ok <- verify_sealed_compilation_artifact(seal, @manifest_filename, manifest_json),
         {:ok, plan} <- decode_compilation_object(plan_json),
         {:ok, manifest} <- decode_compilation_object(manifest_json),
         true <- manifest["graph_hash"] == sha256(dot_source) do
      {:ok,
       %{
         "task_id" => task_id,
         "plan" => plan,
         "dot_source" => dot_source,
         "manifest" => manifest,
         "plan_sha256" => sha256(plan_json),
         "pipeline_sha256" => sha256(dot_source),
         "manifest_sha256" => sha256(manifest_json),
         "artifact_identity" => sha256(seal_json)
       }}
    else
      {:error, :eio} -> {:error, :eio}
      {:error, :unavailable} -> {:error, :unavailable}
      _ -> {:error, :coding_compilation_provenance_unavailable}
    end
  rescue
    _ -> {:error, :coding_compilation_provenance_unavailable}
  catch
    _, _ -> {:error, :coding_compilation_provenance_unavailable}
  end

  @doc """
  Read the host-owned coding terminal evidence for one hashed task root.

  The file must be a mode-`0600` regular file named `coding-terminal-evidence.json`.
  Missing, unreadable, or bad-mode files are unavailable. A present body that
  fails JSON, shape, or schema validation is invalid.
  """
  @spec read_terminal_evidence(String.t(), String.t()) ::
          {:ok, map()}
          | {:error, :coding_terminal_evidence_unavailable | :invalid_coding_terminal_evidence}
  def read_terminal_evidence(base_root, task_id) do
    case acquire_terminal_evidence_bytes(base_root, task_id) do
      {:ok, encoded} ->
        decode_and_validate_terminal_evidence(encoded, task_id)

      {:error, :coding_terminal_evidence_unavailable} ->
        {:error, :coding_terminal_evidence_unavailable}
    end
  end

  @doc """
  Restore exact settled control history from the authenticated first-writer
  `coding-task-terminal.json` when incoming controls are empty.

  Non-empty incoming controls that differ from that archive are rejected.
  Missing first-writer archives leave the incoming list unchanged.
  Unsafe existing targets retain the writer-side fail-closed classifications
  used by `archive_task_terminal/4`.
  """
  @spec reconcile_settled_controls(String.t(), String.t(), list()) ::
          {:ok, list()} | {:error, term()}
  def reconcile_settled_controls(root, task_id, controls) do
    with {:ok, root} <- normalize_task_terminal_root(root),
         :ok <- validate_terminal_task_id(task_id) do
      do_reconcile_settled_controls(root, task_id, controls)
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  @doc """
  Archive the closed, deterministic terminal evidence for a coding task.

  Publication is first-writer-wins: identical replay is idempotent, and a
  conflicting body is rejected without replacing the accepted file.
  """
  @spec archive_terminal_evidence(String.t(), String.t(), map(), list()) ::
          {:ok, map()} | {:error, term()}
  def archive_terminal_evidence(root, task_id, result, controls) do
    with {:ok, root} <- normalize_existing_root(root),
         :ok <- validate_terminal_task_id(task_id),
         :ok <- validate_json_object(result, :invalid_terminal_result),
         :ok <- validate_terminal_result(result),
         {:ok, result} <- normalize_terminal_capacity(result),
         {:ok, result} <- normalize_terminal_verification_report(result),
         {:ok, result} <- normalize_terminal_descriptors(result),
         {:ok, controls} <- do_reconcile_settled_controls(root, task_id, controls),
         {:ok, controls} <- TaskTerminalArchiveCore.validate_control_history(task_id, controls),
         {:ok, body} <- build_terminal_evidence(result, task_id, controls),
         {:ok, encoded} <- encode_canonical_json(body, :terminal_evidence),
         :ok <- validate_terminal_evidence_size(encoded),
         path <- Path.join(root, @terminal_evidence_filename),
         :ok <- write_terminal_evidence_once(path, encoded, root),
         {:ok, descriptor} <- verify_terminal_evidence(path, task_id, encoded) do
      {:ok, descriptor}
    end
  rescue
    exception -> {:error, {:terminal_evidence_error, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:terminal_evidence_throw, {kind, reason}}}
  end

  @doc "Archive the exact canonical envelope for every coding-task terminal."
  @spec archive_task_terminal(String.t(), String.t(), map(), list()) ::
          {:ok, map()} | {:error, term()}
  def archive_task_terminal(root, task_id, terminal_envelope, controls) do
    with {:ok, root} <- normalize_task_terminal_root(root),
         {:ok, controls} <- do_reconcile_settled_controls(root, task_id, controls),
         {:ok, archive} <- TaskTerminalArchiveCore.build(task_id, terminal_envelope, controls),
         path = Path.join(root, @task_terminal_filename),
         :ok <- validate_task_terminal_path(root, path),
         :ok <- write_task_terminal_once(path, archive.encoded, root),
         {:ok, descriptor} <- verify_task_terminal(path, archive) do
      {:ok, descriptor}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_task_terminal_archive}
    end
  rescue
    _exception -> {:error, :task_terminal_archive_error}
  catch
    _kind, _reason -> {:error, :task_terminal_archive_error}
  end

  @doc "Archive immutable proof that a terminal coding candidate was adopted."
  @spec archive_adoption_evidence(String.t(), String.t(), map(), map()) ::
          {:ok, map()} | {:error, term()}
  def archive_adoption_evidence(root, task_id, candidate, proof) do
    with {:ok, root} <- normalize_existing_root(root),
         :ok <- validate_terminal_task_id(task_id),
         :ok <- validate_json_object(candidate, :invalid_adoption_candidate),
         :ok <- validate_json_object(proof, :invalid_adoption_proof),
         true <- Map.get(candidate, "task_id") == task_id,
         body = %{
           "schema_version" => 1,
           "task_id" => task_id,
           "candidate" => candidate,
           "proof" => proof
         },
         {:ok, encoded} <- encode_canonical_json(body, :adoption_evidence),
         :ok <- validate_terminal_evidence_size(encoded),
         path = Path.join(root, @adoption_evidence_prefix <> sha256(encoded) <> ".json"),
         :ok <- write_adoption_evidence_once(path, encoded),
         {:ok, descriptor} <- verify_terminal_evidence(path, task_id, encoded) do
      {:ok, descriptor}
    else
      false -> {:error, :adoption_task_identity_mismatch}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_adoption_evidence}
    end
  rescue
    exception -> {:error, {:adoption_evidence_error, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:adoption_evidence_throw, {kind, reason}}}
  end

  @doc """
  Archive the exact admitted CodingPlan v2 design text as an immutable artifact.

  Filename is fixed as `coding-design-attempt-<attempt>.txt` and never incorporates
  plan or design text. Body size authority is solely
  `DesignArtifactDescriptor.max_bytes/0`.
  """
  @spec archive_design_artifact(String.t(), String.t(), pos_integer(), binary()) ::
          {:ok, map()} | {:error, term()}
  def archive_design_artifact(root, task_id, design_attempt, design)
      when is_binary(root) and is_binary(task_id) and is_integer(design_attempt) and
             is_binary(design) do
    max_bytes = DesignArtifactDescriptor.max_bytes()

    with {:ok, root} <- normalize_existing_root(root),
         :ok <- validate_terminal_task_id(task_id),
         :ok <- validate_design_attempt(design_attempt),
         :ok <- validate_design_body(design, max_bytes),
         path = design_artifact_path(root, design_attempt),
         :ok <- validate_design_artifact_path(root, path),
         :ok <- immutable_write_design(path, design, root),
         {:ok, descriptor} <-
           verify_design_artifact_file(path, root, task_id, design_attempt, design) do
      {:ok, descriptor}
    end
  rescue
    _ -> {:error, :design_artifact_archive_error}
  catch
    _, _ -> {:error, :design_artifact_archive_error}
  end

  def archive_design_artifact(_root, _task_id, _design_attempt, _design),
    do: {:error, :invalid_design_artifact_input}

  @doc """
  Read and re-verify an immutable design artifact against a closed descriptor.

  Fail-closed for missing, replaced, path-escaped, wrong-task, wrong-attempt,
  or digest-mismatched artifacts.
  """
  @spec read_design_artifact(String.t(), String.t(), map()) ::
          {:ok, binary()} | {:error, term()}
  def read_design_artifact(root, task_id, descriptor_input)
      when is_binary(root) and is_binary(task_id) and is_map(descriptor_input) do
    with {:ok, root} <- normalize_existing_root(root),
         :ok <- validate_terminal_task_id(task_id),
         {:ok, descriptor} <- DesignArtifactDescriptor.normalize(descriptor_input),
         true <- descriptor["task_id"] == task_id,
         path = descriptor["path"],
         :ok <- validate_design_artifact_path(root, path),
         expected_path = design_artifact_path(root, descriptor["design_attempt"]),
         true <- path == expected_path,
         {:ok, design} <-
           read_design_artifact_file(path, root, DesignArtifactDescriptor.max_bytes()),
         true <- byte_size(design) == descriptor["byte_size"],
         true <- sha256(design) == descriptor["sha256"] do
      {:ok, design}
    else
      false -> {:error, :design_artifact_unavailable}
      {:error, _reason} = error -> error
      _ -> {:error, :design_artifact_unavailable}
    end
  rescue
    _ -> {:error, :design_artifact_unavailable}
  catch
    _, _ -> {:error, :design_artifact_unavailable}
  end

  def read_design_artifact(_root, _task_id, _descriptor),
    do: {:error, :invalid_design_artifact_input}

  @doc "Append one source-captured ACP turn under this artifact root."
  @spec append_transcript_turn(String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def append_transcript_turn(root, task_id, turn),
    do: TranscriptStore.append_turn(root, task_id, turn)

  @doc "Read and verify the task-bound ACP transcript artifact."
  @spec read_transcript(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def read_transcript(root, task_id), do: TranscriptStore.read(root, task_id)

  @doc "Return the closed descriptor for a verified task-bound ACP transcript."
  @spec transcript_descriptor(String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def transcript_descriptor(root, task_id), do: TranscriptStore.descriptor(root, task_id)

  @doc "Validate the exact public ACP transcript descriptor schema."
  @spec valid_transcript_descriptor?(term()) :: boolean()
  def valid_transcript_descriptor?(descriptor), do: TranscriptStore.valid_descriptor?(descriptor)

  @doc "Persist one immutable, digest-addressed reconciliation envelope.

  The manifest digest addresses the reconciliation decision. The returned
  envelope digest binds the complete persisted bytes, including persistence
  time and supplementary evidence. A different envelope at the same manifest
  path is an intentional immutable conflict.
  "
  @spec archive_reconciliation_manifest(String.t(), map(), map()) ::
          {:ok, map()} | {:error, term()}
  def archive_reconciliation_manifest(root, scope, envelope) do
    with {:ok, root} <- normalize_root(root),
         :ok <- validate_json_object(scope, :invalid_reconciliation_scope),
         {:ok, envelope} <- normalize_reconciliation_envelope(envelope),
         :ok <- reconciliation_scope_matches?(scope, envelope["manifest"]["scope"]),
         {:ok, encoded} <- encode_reconciliation_json(envelope),
         true <- byte_size(encoded) <= @max_reconciliation_bytes,
         :ok <- create_root(root),
         {:ok, scope_digest} <- reconciliation_scope_digest(scope),
         envelope_sha256 <- sha256(encoded),
         path <- reconciliation_manifest_path(root, scope_digest, envelope["manifest_sha256"]),
         :ok <- ensure_reconciliation_directories(root, path),
         :ok <- validate_reconciliation_path(root, path),
         :ok <- immutable_write(path, encoded, root),
         :ok <-
           verify_reconciliation_file(
             path,
             encoded,
             envelope["manifest_sha256"],
             envelope_sha256,
             scope_digest
           ) do
      {:ok,
       %{
         "reconciliation_manifest_path" => path,
         "manifest_sha256" => envelope["manifest_sha256"],
         "envelope_sha256" => envelope_sha256,
         "scope_sha256" => scope_digest,
         "byte_size" => byte_size(encoded)
       }}
    else
      false -> {:error, {:reconciliation_manifest_too_large, @max_reconciliation_bytes}}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_reconciliation_manifest}
    end
  rescue
    _exception -> {:error, :reconciliation_manifest_error}
  catch
    _kind, _reason -> {:error, :reconciliation_manifest_throw}
  end

  @doc "Read and re-verify an immutable reconciliation envelope by scope and digest."
  @spec read_reconciliation_manifest(String.t(), map(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def read_reconciliation_manifest(root, scope, manifest_sha256)
      when is_binary(manifest_sha256),
      do: read_reconciliation_manifest(root, scope, manifest_sha256, nil)

  def read_reconciliation_manifest(_root, _scope, _manifest_sha256),
    do: {:error, :invalid_reconciliation_manifest_digest}

  @doc "Read an envelope and optionally bind its complete persisted bytes."
  @spec read_reconciliation_manifest(String.t(), map(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def read_reconciliation_manifest(root, scope, manifest_sha256, expected_envelope_sha256)
      when is_binary(manifest_sha256) do
    with {:ok, root} <- normalize_root(root),
         :ok <- validate_json_object(scope, :invalid_reconciliation_scope),
         :ok <- validate_sha256(manifest_sha256, :manifest_sha256),
         :ok <- validate_optional_sha256(expected_envelope_sha256, :envelope_sha256),
         {:ok, scope_digest} <- reconciliation_scope_digest(scope),
         path <- reconciliation_manifest_path(root, scope_digest, manifest_sha256),
         {:ok, encoded} <- File.read(path),
         {:ok, envelope} <- decode_reconciliation_envelope(encoded),
         :ok <-
           verify_reconciliation_file(
             path,
             encoded,
             manifest_sha256,
             expected_envelope_sha256 || sha256(encoded),
             scope_digest
           ) do
      {:ok, envelope}
    else
      {:error, :enoent} -> {:error, :reconciliation_manifest_not_found}
      {:error, _reason} = error -> error
      _other -> {:error, :reconciliation_manifest_verification_failed}
    end
  end

  def read_reconciliation_manifest(_root, _scope, _manifest_sha256, _expected_envelope_sha256),
    do: {:error, :invalid_reconciliation_manifest_digest}

  @doc """
  Archive one sealed CrossApp static-stage receipt under the hashed task root.

  Filename and destination are store-owned. Callers supply `base_root` plus the
  exact `task_id`, `continuation_id`, and expected receipt digest; they never
  select the path. Publication is first-writer / no-clobber among callers of
  this API, not an OS guarantee against a same-UID process that can unlink,
  chmod, or replace the task root or file. Persisted envelopes are JSON-clean
  and token-free.
  """
  @spec archive_cross_app_task_static_receipt(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          map()
        ) :: {:ok, map()} | {:error, term()}
  def archive_cross_app_task_static_receipt(
        base_root,
        task_id,
        continuation_id,
        expected_digest,
        receipt
      )
      when is_binary(base_root) and is_binary(task_id) and is_binary(continuation_id) and
             is_binary(expected_digest) and is_map(receipt) and not is_struct(receipt) do
    with :ok <- validate_terminal_task_id(task_id),
         :ok <- validate_sha256(expected_digest, :receipt_sha256),
         :ok <- validate_static_receipt_continuation_id(continuation_id),
         {:ok, admitted} <-
           Actions.coding_cross_app_static_receipt_admit(receipt),
         {:ok, digest} <-
           Actions.coding_cross_app_static_receipt_digest(admitted),
         :ok <- match_static_receipt_task_id(admitted, task_id),
         :ok <- match_static_receipt_continuation_id(admitted, continuation_id),
         :ok <- match_static_receipt_digest(digest, expected_digest),
         {:ok, encoded} <- encode_compact_canonical_json(admitted, :static_receipt),
         {:ok, max_bytes} <- static_receipt_max_json_bytes(),
         :ok <- validate_static_receipt_size(encoded, max_bytes),
         {:ok, task_root} <- ensure_static_receipt_task_root(base_root, task_id),
         path = Path.join(task_root, @static_receipt_filename),
         :ok <- validate_static_receipt_path(task_root, path),
         :ok <- write_static_receipt_once(path, encoded, task_root),
         {:ok, descriptor} <-
           verify_published_static_receipt(
             base_root,
             task_id,
             continuation_id,
             expected_digest
           ) do
      {:ok, descriptor}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :static_receipt_archive_error}
    end
  rescue
    _ -> {:error, :static_receipt_archive_error}
  catch
    _, _ -> {:error, :static_receipt_archive_error}
  end

  def archive_cross_app_task_static_receipt(
        _base_root,
        _task_id,
        _continuation_id,
        _expected_digest,
        _receipt
      ),
      do: {:error, :invalid_static_receipt_input}

  @doc """
  Read and re-verify the store-owned CrossApp static-stage receipt.

  Resolves `base_root` plus the hashed exact task id to a fixed basename.
  Missing, malformed, oversized, noncanonical, wrong-mode, symlink, hard-link,
  directory, replaced, or tampered files fail closed. After admission, the
  supplied task id, continuation id, and expected digest must exact-match.
  Returns only the canonical admitted receipt plus a bounded JSON-clean
  descriptor. Immutability is API-level first-writer / no-clobber, not an OS
  guarantee against a malicious same-UID process.
  """
  @spec read_cross_app_task_static_receipt(
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, map()} | {:error, term()}
  def read_cross_app_task_static_receipt(
        base_root,
        task_id,
        continuation_id,
        expected_digest
      )
      when is_binary(base_root) and is_binary(task_id) and is_binary(continuation_id) and
             is_binary(expected_digest) do
    with :ok <- validate_terminal_task_id(task_id),
         :ok <- validate_sha256(expected_digest, :receipt_sha256),
         :ok <- validate_static_receipt_continuation_id(continuation_id),
         {:ok, encoded, admitted, digest} <-
           load_and_admit_static_receipt(base_root, task_id),
         :ok <- match_static_receipt_task_id(admitted, task_id),
         :ok <- match_static_receipt_continuation_id(admitted, continuation_id),
         :ok <- match_static_receipt_digest(digest, expected_digest) do
      {:ok,
       %{
         "receipt" => admitted,
         "descriptor" => static_receipt_descriptor(task_id, continuation_id, digest, encoded)
       }}
    else
      {:error, :static_receipt_task_identity_mismatch} = error -> error
      {:error, :static_receipt_continuation_mismatch} = error -> error
      {:error, :static_receipt_digest_mismatch} = error -> error
      _ -> {:error, :cross_app_static_receipt_unavailable}
    end
  rescue
    _ -> {:error, :cross_app_static_receipt_unavailable}
  catch
    _, _ -> {:error, :cross_app_static_receipt_unavailable}
  end

  def read_cross_app_task_static_receipt(
        _base_root,
        _task_id,
        _continuation_id,
        _expected_digest
      ),
      do: {:error, :invalid_static_receipt_input}

  @doc """
  Archive one Engine-native CrossApp static-stage receipt generation.

  Filename is the exact receipt digest under a store-owned directory in the
  hashed task root. Callers never select the path. Distinct digests coexist
  up to #{@engine_static_receipt_generation_limit} generations. Same-digest
  retry is idempotent; a different body for an existing digest conflicts.
  """
  @spec archive_cross_app_static_receipt(String.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def archive_cross_app_static_receipt(base_root, task_id, expected_digest, receipt)
      when is_binary(base_root) and is_binary(task_id) and is_binary(expected_digest) and
             is_map(receipt) and not is_struct(receipt) do
    with :ok <- validate_terminal_task_id(task_id),
         :ok <- validate_sha256(expected_digest, :receipt_sha256),
         {:ok, admitted} <-
           Actions.coding_cross_app_static_receipt_admit(receipt),
         {:ok, digest} <-
           Actions.coding_cross_app_static_receipt_digest(admitted),
         :ok <- match_static_receipt_task_id(admitted, task_id),
         :ok <- match_static_receipt_digest(digest, expected_digest),
         {:ok, encoded} <- encode_compact_canonical_json(admitted, :static_receipt),
         {:ok, max_bytes} <- static_receipt_max_json_bytes(),
         :ok <- validate_static_receipt_size(encoded, max_bytes),
         {:ok, task_root} <- ensure_static_receipt_task_root(base_root, task_id),
         {:ok, generation_root} <- ensure_engine_static_receipt_generation_root(task_root),
         path = engine_static_receipt_path(generation_root, digest),
         :ok <- validate_engine_static_receipt_path(generation_root, path, digest),
         :ok <-
           enforce_engine_static_receipt_generation_limit(generation_root, path),
         :ok <- write_engine_static_receipt_once(path, encoded, generation_root),
         {:ok, descriptor} <-
           verify_published_engine_static_receipt(base_root, task_id, expected_digest) do
      {:ok, descriptor}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :static_receipt_archive_error}
    end
  rescue
    _ -> {:error, :static_receipt_archive_error}
  catch
    _, _ -> {:error, :static_receipt_archive_error}
  end

  def archive_cross_app_static_receipt(_base_root, _task_id, _expected_digest, _receipt),
    do: {:error, :invalid_static_receipt_input}

  @doc """
  Read and re-verify one Engine-native CrossApp static-stage receipt generation.

  Resolves only the store-owned digest filename under the hashed task root.
  """
  @spec read_cross_app_static_receipt(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def read_cross_app_static_receipt(base_root, task_id, expected_digest)
      when is_binary(base_root) and is_binary(task_id) and is_binary(expected_digest) do
    with :ok <- validate_terminal_task_id(task_id),
         :ok <- validate_sha256(expected_digest, :receipt_sha256),
         {:ok, encoded, admitted, digest} <-
           load_and_admit_engine_static_receipt(base_root, task_id, expected_digest),
         :ok <- match_static_receipt_task_id(admitted, task_id),
         :ok <- match_static_receipt_digest(digest, expected_digest) do
      {:ok,
       %{
         "receipt" => admitted,
         "descriptor" => engine_static_receipt_descriptor(task_id, digest, encoded)
       }}
    else
      {:error, :static_receipt_task_identity_mismatch} = error -> error
      {:error, :static_receipt_digest_mismatch} = error -> error
      {:error, :static_receipt_generation_limit} = error -> error
      _ -> {:error, :cross_app_static_receipt_unavailable}
    end
  rescue
    _ -> {:error, :cross_app_static_receipt_unavailable}
  catch
    _, _ -> {:error, :cross_app_static_receipt_unavailable}
  end

  def read_cross_app_static_receipt(_base_root, _task_id, _expected_digest),
    do: {:error, :invalid_static_receipt_input}

  defp normalize_reconciliation_envelope(envelope)
       when is_map(envelope) and not is_struct(envelope) do
    with :ok <- validate_json_object(envelope, :invalid_reconciliation_envelope),
         :ok <- exact_reconciliation_envelope_keys(envelope),
         1 <- envelope["schema_version"],
         {:ok, manifest} <- ReconciliationManifest.normalize(envelope["manifest"]),
         {:ok, manifest_sha256} <- ReconciliationManifest.digest(manifest),
         :ok <- validate_sha256(envelope["manifest_sha256"], :manifest_sha256),
         true <- manifest_sha256 == envelope["manifest_sha256"],
         {:ok, persisted_at} <- normalize_persisted_at(envelope["persisted_at"]),
         {:ok, supplementary} <- normalize_supplementary(envelope["supplementary_evidence"]) do
      {:ok,
       %{
         "schema_version" => 1,
         "manifest" => manifest,
         "manifest_sha256" => manifest_sha256,
         "persisted_at" => persisted_at,
         "supplementary_evidence" => supplementary
       }}
    else
      false -> {:error, :reconciliation_manifest_digest_mismatch}
      _ -> {:error, :invalid_reconciliation_envelope}
    end
  end

  defp normalize_reconciliation_envelope(_envelope),
    do: {:error, :invalid_reconciliation_envelope}

  defp decode_reconciliation_envelope(encoded) when is_binary(encoded) do
    with {:ok, decoded} <- Jason.decode(encoded),
         {:ok, envelope} <- normalize_reconciliation_envelope(decoded) do
      {:ok, envelope}
    else
      _ -> {:error, :invalid_reconciliation_envelope}
    end
  end

  defp encode_reconciliation_json(value) do
    with {:ok, canonical} <- CodingRunRecoveryCore.canonical_json(value),
         {:ok, encoded} <- Jason.encode(canonical, pretty: true) do
      {:ok, encoded}
    else
      _ -> {:error, :invalid_reconciliation_manifest}
    end
  rescue
    _ -> {:error, :invalid_reconciliation_manifest}
  catch
    _, _ -> {:error, :invalid_reconciliation_manifest}
  end

  defp exact_reconciliation_envelope_keys(envelope) do
    if Enum.sort(Map.keys(envelope)) ==
         ~w(manifest manifest_sha256 persisted_at schema_version supplementary_evidence),
       do: :ok,
       else: {:error, :invalid_reconciliation_envelope}
  end

  defp normalize_persisted_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, DateTime.to_iso8601(DateTime.shift_zone!(datetime, "Etc/UTC"), :extended)}

      _ ->
        {:error, :invalid_persisted_at}
    end
  end

  defp normalize_persisted_at(_value), do: {:error, :invalid_persisted_at}

  defp normalize_supplementary(value) when is_map(value) and not is_struct(value) do
    if validate_json_object(value, :invalid_supplementary_evidence) == :ok,
      do: {:ok, value},
      else: {:error, :invalid_supplementary_evidence}
  end

  defp normalize_supplementary(_value), do: {:error, :invalid_supplementary_evidence}

  defp reconciliation_scope_digest(scope) do
    with {:ok, canonical} <- CodingRunRecoveryCore.canonical_json(scope),
         {:ok, encoded} <- Jason.encode(canonical) do
      {:ok, sha256(encoded)}
    else
      {:error, reason} -> {:error, {:invalid_reconciliation_scope, reason}}
      _ -> {:error, :invalid_reconciliation_scope}
    end
  end

  defp reconciliation_scope_matches?(scope, scope), do: :ok

  defp reconciliation_scope_matches?(_scope, _manifest_scope),
    do: {:error, :reconciliation_scope_mismatch}

  defp validate_reconciliation_path(root, path) do
    with {:ok, _lexical} <- SafePath.resolve_within(path, root),
         {:ok, real_root} <- SafePath.resolve_real(root),
         {:ok, real_parent} <- SafePath.resolve_real(Path.dirname(path)),
         true <- SafePath.within?(real_parent, real_root) do
      :ok
    else
      _ -> {:error, :reconciliation_manifest_path_escape}
    end
  end

  defp ensure_reconciliation_directories(root, path) do
    reconciliation_root = Path.join(root, @reconciliation_directory)
    scope_root = Path.dirname(path)

    with :ok <- ensure_directory(root),
         :ok <- ensure_directory(reconciliation_root),
         :ok <- ensure_directory(scope_root) do
      :ok
    end
  end

  defp ensure_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :reconciliation_manifest_symlink}

      {:ok, _other} ->
        {:error, :invalid_reconciliation_manifest_directory}

      {:error, :enoent} ->
        case File.mkdir(path) do
          :ok -> ensure_directory(path)
          {:error, :eexist} -> ensure_directory(path)
          {:error, reason} -> {:error, {:create_reconciliation_directory_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:reconciliation_manifest_unavailable, reason}}
    end
  end

  defp reconciliation_manifest_path(root, scope_digest, manifest_sha256) do
    Path.join([
      root,
      @reconciliation_directory,
      "scope-" <> scope_digest,
      "manifest-" <> manifest_sha256 <> ".json"
    ])
  end

  defp immutable_write(path, content, root) do
    case File.lstat(path) do
      {:error, :enoent} ->
        immutable_atomic_write(path, content, root)

      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        with true <- Bitwise.band(mode, 0o777) == 0o600,
             {:ok, existing} <- File.read(path),
             true <- existing == content do
          :ok
        else
          false -> {:error, :reconciliation_manifest_conflict}
          {:error, reason} -> {:error, {:reconciliation_manifest_unreadable, reason}}
        end

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :reconciliation_manifest_symlink}

      {:ok, _other} ->
        {:error, :invalid_reconciliation_manifest_file}

      {:error, reason} ->
        {:error, {:reconciliation_manifest_unavailable, reason}}
    end
  end

  defp immutable_atomic_write(path, content, root) do
    temporary_path = temporary_path(path)

    try do
      with :ok <- validate_reconciliation_path(root, path),
           :ok <- validate_existing_reconciliation_directory(Path.dirname(path)),
           :ok <- write_secure_temp(temporary_path, content),
           :ok <- File.ln(temporary_path, path) do
        :ok
      else
        {:error, :eexist} -> immutable_write(path, content, root)
        {:error, reason} -> {:error, {:write_reconciliation_manifest_failed, reason}}
      end
    after
      File.rm(temporary_path)
    end
  end

  defp verify_reconciliation_file(
         path,
         expected_encoded,
         expected_digest,
         expected_envelope_digest,
         scope_digest
       ) do
    with {:ok, %File.Stat{type: :regular, mode: mode}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o777) == 0o600,
         {:ok, encoded} <- File.read(path),
         true <- encoded == expected_encoded,
         true <- sha256(encoded) == expected_envelope_digest,
         {:ok, envelope} <- decode_reconciliation_envelope(encoded),
         true <- envelope["manifest_sha256"] == expected_digest,
         {:ok, actual_scope_digest} <- reconciliation_scope_digest(envelope["manifest"]["scope"]),
         true <- actual_scope_digest == scope_digest do
      :ok
    else
      false -> {:error, :reconciliation_manifest_verification_failed}
      {:error, reason} -> {:error, {:reconciliation_manifest_verification_failed, reason}}
      _ -> {:error, :reconciliation_manifest_verification_failed}
    end
  end

  defp validate_existing_reconciliation_directory(path) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(path),
         {:ok, real_path} <- SafePath.resolve_real(path),
         true <- File.dir?(real_path) do
      :ok
    else
      {:error, :enoent} -> {:error, :reconciliation_manifest_directory_missing}
      {:error, _reason} -> {:error, :reconciliation_manifest_directory_unavailable}
      _ -> {:error, :invalid_reconciliation_manifest_directory}
    end
  end

  defp validate_sha256(value, _field)
       when is_binary(value) and byte_size(value) == 64 do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, value), do: :ok, else: {:error, :invalid_sha256}
  end

  defp validate_sha256(_value, field), do: {:error, {:invalid_sha256, field}}

  defp validate_optional_sha256(nil, _field), do: :ok
  defp validate_optional_sha256(value, field), do: validate_sha256(value, field)

  defp normalize_root(root) when is_binary(root) do
    cond do
      not String.valid?(root) ->
        {:error, {:invalid_root, :invalid_encoding}}

      String.trim(root) == "" ->
        {:error, {:invalid_root, :empty}}

      String.contains?(root, <<0>>) ->
        {:error, {:invalid_root, :null_byte}}

      true ->
        try do
          {:ok, Path.expand(root)}
        rescue
          _ -> {:error, {:invalid_root, :invalid_path}}
        end
    end
  end

  defp normalize_root(_root), do: {:error, {:invalid_root, :expected_string}}

  defp normalize_compilation_base(root) do
    with {:ok, expanded} <- normalize_root(root),
         true <- SafePath.absolute?(expanded),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(expanded),
         {:ok, canonical} <- SafePath.resolve_real(expanded),
         true <- File.dir?(canonical) do
      {:ok, canonical}
    else
      {:error, :eio} -> {:error, :eio}
      _ -> {:error, :invalid_compilation_base}
    end
  end

  defp compilation_task_root(base_root, task_id) do
    digest =
      task_id
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    with {:ok, task_root} <- SafePath.safe_join(base_root, "task-" <> digest),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(task_root),
         {:ok, canonical} <- SafePath.resolve_real(task_root),
         true <- canonical == task_root and SafePath.within?(canonical, base_root) do
      {:ok, canonical}
    else
      {:error, :eio} -> {:error, :eio}
      _ -> {:error, :invalid_compilation_task_root}
    end
  end

  defp acquire_terminal_evidence_bytes(base_root, task_id) do
    with :ok <- validate_terminal_task_id(task_id),
         {:ok, base_root} <- normalize_compilation_base(base_root),
         {:ok, task_root} <- compilation_task_root(base_root, task_id),
         path = Path.join(task_root, @terminal_evidence_filename),
         {:ok, encoded} <-
           read_compilation_file(path, task_root, @max_terminal_evidence_bytes) do
      {:ok, encoded}
    else
      _ -> {:error, :coding_terminal_evidence_unavailable}
    end
  rescue
    _ -> {:error, :coding_terminal_evidence_unavailable}
  catch
    _, _ -> {:error, :coding_terminal_evidence_unavailable}
  end

  defp decode_and_validate_terminal_evidence(encoded, task_id) do
    with {:ok, body} <- Jason.decode(encoded),
         true <- is_map(body) and not is_struct(body),
         true <- Enum.all?(Map.keys(body), &is_binary/1),
         :ok <- validate_archived_terminal_evidence(body, task_id) do
      {:ok, body}
    else
      _ -> {:error, :invalid_coding_terminal_evidence}
    end
  rescue
    _ -> {:error, :invalid_coding_terminal_evidence}
  catch
    _, _ -> {:error, :invalid_coding_terminal_evidence}
  end

  defp read_compilation_file(path, task_root, max_bytes) do
    with true <- Path.dirname(path) == task_root,
         {:ok, canonical} <- SafePath.resolve_real(path),
         true <- canonical == path and SafePath.within?(canonical, task_root),
         {:ok, content} <- read_descriptor_bounded_file(path, max_bytes) do
      {:ok, content}
    else
      {:error, :eio} -> {:error, :eio}
      {:error, :unavailable} -> {:error, :unavailable}
      _ -> {:error, :invalid_compilation_artifact}
    end
  end

  defp decode_compilation_seal(encoded) do
    with {:ok, seal} <- Jason.decode(encoded),
         true <- exact_string_keys?(seal, ["artifacts", "schema_version"]),
         true <- seal["schema_version"] == @compilation_seal_schema_version,
         artifacts when is_map(artifacts) <- seal["artifacts"],
         true <- Enum.sort(Map.keys(artifacts)) == Enum.sort(@compilation_artifact_filenames),
         true <- Enum.all?(artifacts, &valid_compilation_seal_entry?/1),
         {:ok, canonical} <- encode_canonical_json(seal, :compilation_seal),
         true <- canonical == encoded do
      {:ok, seal}
    else
      _ -> {:error, :invalid_compilation_seal}
    end
  end

  defp valid_compilation_seal_entry?({filename, entry}) do
    filename in @compilation_artifact_filenames and
      exact_string_keys?(entry, ["byte_size", "sha256"]) and
      is_integer(entry["byte_size"]) and entry["byte_size"] > 0 and
      entry["byte_size"] <= @max_compilation_artifact_bytes and
      valid_lower_sha256?(entry["sha256"])
  end

  defp valid_compilation_seal_entry?(_entry), do: false

  defp exact_string_keys?(value, expected) when is_map(value) and not is_struct(value),
    do: Enum.sort(Map.keys(value)) == expected

  defp exact_string_keys?(_value, _expected), do: false

  defp valid_lower_sha256?(value) when is_binary(value) and byte_size(value) == 64,
    do: Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp valid_lower_sha256?(_value), do: false

  defp verify_sealed_compilation_artifact(seal, filename, content) do
    expected = get_in(seal, ["artifacts", filename])

    if is_map(expected) and expected["byte_size"] == byte_size(content) and
         expected["sha256"] == sha256(content) do
      :ok
    else
      {:error, :compilation_seal_mismatch}
    end
  end

  defp decode_compilation_object(encoded) do
    with {:ok, value} <- Jason.decode(encoded),
         :ok <- validate_json_object(value, :invalid_compilation_artifact) do
      {:ok, value}
    else
      _ -> {:error, :invalid_compilation_artifact}
    end
  end

  defp normalize_existing_root(root) do
    with {:ok, expanded} <- normalize_root(root),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(expanded),
         {:ok, canonical} <- SafePath.resolve_real(expanded),
         true <- File.dir?(canonical) do
      {:ok, canonical}
    else
      {:error, reason} -> {:error, {:invalid_terminal_root, reason}}
      _ -> {:error, {:invalid_terminal_root, :not_real_directory}}
    end
  end

  defp normalize_task_terminal_root(root) do
    with {:ok, expanded} <- normalize_root(root),
         true <- SafePath.absolute?(expanded),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(expanded),
         {:ok, canonical} <- SafePath.resolve_real(expanded),
         true <- File.dir?(canonical) do
      {:ok, canonical}
    else
      _ -> {:error, :invalid_task_terminal_root}
    end
  end

  defp validate_terminal_task_id(task_id)
       when is_binary(task_id) and byte_size(task_id) <= @max_terminal_task_id_bytes do
    if String.valid?(task_id) and String.trim(task_id) != "" and
         not String.contains?(task_id, <<0>>) and
         not String.match?(task_id, ~r/[\x00-\x1F\x7F]/) do
      :ok
    else
      {:error, {:invalid_terminal_task_id, :invalid_value}}
    end
  end

  defp validate_terminal_task_id(_task_id),
    do: {:error, {:invalid_terminal_task_id, :invalid_value}}

  defp validate_terminal_result(result) do
    required = MapSet.new(~w(status canonical_status outcome artifacts))

    with :ok <- validate_terminal_keys(result, @terminal_result_keys, :terminal_result),
         true <- MapSet.subset?(required, Map.keys(result) |> MapSet.new()),
         {:ok, _status} <- required_terminal_string(result, "status"),
         {:ok, canonical_status} <- required_terminal_string(result, "canonical_status"),
         true <- OutcomeMapper.terminal_status?(Map.fetch!(result, "status")),
         true <- OutcomeMapper.terminal_status?(canonical_status),
         true <-
           OutcomeMapper.compatible_with_status?(Map.fetch!(result, "outcome"), canonical_status),
         :ok <- validate_terminal_artifacts(Map.fetch!(result, "artifacts")),
         :ok <- validate_terminal_optional_data(result),
         :ok <- validate_terminal_capacity_consistency(result) do
      :ok
    else
      false -> {:error, {:invalid_terminal_result, :not_successful}}
      {:error, _reason} = error -> error
      _ -> {:error, {:invalid_terminal_result, :malformed}}
    end
  end

  defp validate_terminal_keys(result, allowed, error_tag) do
    keys = Map.keys(result) |> MapSet.new()

    if MapSet.subset?(keys, allowed),
      do: :ok,
      else: {:error, {error_tag, :unknown_key}}
  end

  defp required_terminal_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 ->
        if String.valid?(value) and String.trim(value) != "",
          do: {:ok, value},
          else: {:error, {:invalid_terminal_field, key}}

      _ ->
        {:error, {:invalid_terminal_field, key}}
    end
  end

  defp validate_terminal_artifacts(artifacts)
       when is_map(artifacts) and not is_struct(artifacts) do
    required =
      MapSet.new(
        ~w(coding_plan_path coding_pipeline_path compile_manifest_path graph_hash compiler_version)
      )

    keys = Map.keys(artifacts) |> MapSet.new()

    with true <- MapSet.subset?(required, keys),
         true <-
           MapSet.subset?(
             keys,
             MapSet.union(
               required,
               MapSet.new(~w(acp_transcript workspace_release branch_lifecycle))
             )
           ),
         :ok <- validate_terminal_path(artifacts["coding_plan_path"]),
         :ok <- validate_terminal_path(artifacts["coding_pipeline_path"]),
         :ok <- validate_terminal_path(artifacts["compile_manifest_path"]),
         :ok <- validate_terminal_hash(artifacts["graph_hash"]),
         :ok <- required_terminal_string(artifacts, "compiler_version") |> discard_value(),
         :ok <-
           validate_terminal_artifact_descriptor(
             artifacts,
             "workspace_release",
             WorkspaceReleaseDescriptor
           ),
         :ok <-
           validate_terminal_artifact_descriptor(
             artifacts,
             "branch_lifecycle",
             BranchLifecycleDescriptor
           ) do
      :ok
    else
      false -> {:error, {:invalid_terminal_artifacts, :fields}}
      {:error, _reason} = error -> error
      _ -> {:error, {:invalid_terminal_artifacts, :fields}}
    end
  end

  defp validate_terminal_artifacts(_artifacts),
    do: {:error, {:invalid_terminal_artifacts, :expected_map}}

  defp discard_value({:ok, _value}), do: :ok
  defp discard_value({:error, _reason} = error), do: error

  defp validate_terminal_path(path) when is_binary(path) do
    if String.valid?(path) and byte_size(path) <= 4_096 and String.trim(path) != "" and
         SafePath.absolute?(path) and Path.expand(path) == path and
         not String.contains?(path, <<0>>) and not String.match?(path, ~r/[\x00-\x1F\x7F]/) do
      :ok
    else
      {:error, {:invalid_terminal_artifact_path, path}}
    end
  end

  defp validate_terminal_path(_path), do: {:error, {:invalid_terminal_artifact_path, :invalid}}

  defp validate_terminal_hash(hash) when is_binary(hash) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, hash),
      do: :ok,
      else: {:error, {:invalid_terminal_artifact_hash, :graph_hash}}
  end

  defp validate_terminal_hash(_hash),
    do: {:error, {:invalid_terminal_artifact_hash, :graph_hash}}

  defp validate_terminal_optional_data(result) do
    with :ok <- validate_terminal_validation(Map.get(result, "validation")),
         :ok <- validate_terminal_verification_report(result),
         :ok <- validate_terminal_verification_consistency(result),
         :ok <- validate_terminal_review(Map.get(result, "review")),
         :ok <-
           validate_terminal_descriptor_field(
             result,
             "workspace_release",
             WorkspaceReleaseDescriptor
           ),
         :ok <-
           validate_terminal_descriptor_field(
             result,
             "branch_lifecycle",
             BranchLifecycleDescriptor
           ) do
      validate_terminal_metrics(Map.get(result, "metrics"))
    end
  end

  defp validate_terminal_verification_report(result) do
    case Map.fetch(result, "verification_report") do
      :error ->
        :ok

      {:ok, report} ->
        if VerificationReport.valid?(report),
          do: :ok,
          else: {:error, {:invalid_terminal_field, "verification_report"}}
    end
  end

  defp validate_terminal_verification_consistency(result) do
    case Map.fetch(result, "verification_report") do
      :error ->
        :ok

      {:ok, %{"status" => report_status}} ->
        status = Map.get(result, "status")
        canonical_status = Map.get(result, "canonical_status")

        cond do
          status == "validation_failed" ->
            if canonical_status in ~w(validation_failed rework_exhausted) and
                 report_status in ~w(failed blocked),
               do: :ok,
               else: verification_mismatch()

          canonical_status == "validation_failed" ->
            verification_mismatch()

          status == "validation_capacity_exceeded" or
              canonical_status == "validation_capacity_exceeded" ->
            if status == "validation_capacity_exceeded" and
                 canonical_status == "validation_capacity_exceeded" and
                 report_status == "blocked",
               do: :ok,
               else: verification_mismatch()

          report_status == "passed" ->
            :ok

          true ->
            verification_mismatch()
        end

      _other ->
        verification_mismatch()
    end
  end

  defp verification_mismatch,
    do: {:error, {:invalid_terminal_result, :verification_status_mismatch}}

  defp normalize_terminal_verification_report(result) do
    case Map.fetch(result, "verification_report") do
      :error ->
        {:ok, result}

      {:ok, report} ->
        case VerificationReport.normalize(report) do
          {:ok, normalized} ->
            {:ok, Map.put(result, "verification_report", normalized)}

          {:error, reason} ->
            {:error, {:invalid_terminal_field, {"verification_report", reason}}}
        end
    end
  end

  defp normalize_terminal_capacity(result),
    do: ValidationCapacityTerminal.normalize_result(result, :terminal)

  defp validate_terminal_capacity_consistency(result),
    do: ValidationCapacityTerminal.validate_consistency(result, :terminal)

  defp validate_terminal_artifact_descriptor(artifacts, key, contract) do
    case Map.fetch(artifacts, key) do
      :error ->
        :ok

      {:ok, value} ->
        if contract.valid?(value), do: :ok, else: {:error, {:invalid_terminal_artifact, key}}
    end
  end

  defp validate_terminal_descriptor_field(result, key, contract) do
    case Map.fetch(result, key) do
      :error ->
        :ok

      {:ok, value} ->
        if contract.valid?(value), do: :ok, else: {:error, {:invalid_terminal_field, key}}
    end
  end

  defp normalize_terminal_descriptors(result) do
    with {:ok, workspace_release} <-
           normalize_optional_terminal_descriptor(
             result,
             "workspace_release",
             WorkspaceReleaseDescriptor
           ),
         {:ok, branch_lifecycle} <-
           normalize_optional_terminal_descriptor(
             result,
             "branch_lifecycle",
             BranchLifecycleDescriptor
           ),
         {:ok, artifacts} <-
           normalize_terminal_artifacts(
             Map.fetch!(result, "artifacts"),
             workspace_release,
             branch_lifecycle
           ) do
      {:ok,
       result
       |> maybe_put_terminal_descriptor("workspace_release", workspace_release)
       |> maybe_put_terminal_descriptor("branch_lifecycle", branch_lifecycle)
       |> Map.put("artifacts", artifacts)}
    end
  end

  defp normalize_optional_terminal_descriptor(result, key, contract) do
    case Map.fetch(result, key) do
      :error ->
        {:ok, nil}

      {:ok, value} ->
        case contract.normalize(value) do
          {:ok, normalized} -> {:ok, normalized}
          {:error, reason} -> {:error, {:invalid_terminal_field, {key, reason}}}
        end
    end
  end

  defp normalize_terminal_artifacts(artifacts, workspace_release, branch_lifecycle) do
    with {:ok, artifact_workspace_release} <-
           normalize_optional_terminal_artifact(
             artifacts,
             "workspace_release",
             workspace_release,
             WorkspaceReleaseDescriptor
           ),
         {:ok, artifact_branch_lifecycle} <-
           normalize_optional_terminal_artifact(
             artifacts,
             "branch_lifecycle",
             branch_lifecycle,
             BranchLifecycleDescriptor
           ),
         :ok <-
           matching_terminal_descriptors(
             workspace_release,
             artifact_workspace_release,
             "workspace_release"
           ),
         :ok <-
           matching_terminal_descriptors(
             branch_lifecycle,
             artifact_branch_lifecycle,
             "branch_lifecycle"
           ) do
      {:ok,
       artifacts
       |> maybe_put_terminal_descriptor("workspace_release", artifact_workspace_release)
       |> maybe_put_terminal_descriptor("branch_lifecycle", artifact_branch_lifecycle)}
    end
  end

  # Top-level lifecycle facts and artifact lifecycle facts must not diverge.
  # The artifact fallback above makes a top-level-only descriptor canonical in
  # the artifact map; an explicitly supplied artifact is compared after both
  # values have been normalized by its contract.
  defp matching_terminal_descriptors(top_level, artifact, _key) when top_level == artifact,
    do: :ok

  defp matching_terminal_descriptors(nil, _artifact, _key), do: :ok

  defp matching_terminal_descriptors(_top_level, _artifact, key),
    do: {:error, {:terminal_descriptor_mismatch, key}}

  defp normalize_optional_terminal_artifact(artifacts, key, fallback, contract) do
    case Map.fetch(artifacts, key) do
      :error ->
        {:ok, fallback}

      {:ok, value} ->
        case contract.normalize(value) do
          {:ok, normalized} -> {:ok, normalized}
          {:error, reason} -> {:error, {:invalid_terminal_artifact, {key, reason}}}
        end
    end
  end

  defp maybe_put_terminal_descriptor(map, _key, nil), do: map
  defp maybe_put_terminal_descriptor(map, key, value), do: Map.put(map, key, value)

  defp validate_terminal_validation(nil), do: :ok
  defp validate_terminal_validation(value) when is_list(value), do: validate_json_value(value, [])

  defp validate_terminal_validation(_value),
    do: {:error, {:invalid_terminal_validation, :expected_list}}

  defp validate_terminal_review(nil), do: :ok

  defp validate_terminal_review(value) when is_map(value) and not is_struct(value),
    do: validate_json_object(value, :invalid_terminal_review)

  defp validate_terminal_review(_value), do: {:error, {:invalid_terminal_review, :expected_map}}

  defp build_terminal_evidence(result, task_id, controls) do
    artifacts = Map.fetch!(result, "artifacts")
    validation = Map.get(result, "validation") || []
    review = terminal_review_verdict(result)

    body =
      %{
        "schema_version" => 1,
        "task_id" => task_id,
        "terminal_status" => Map.fetch!(result, "status"),
        "canonical_status" => Map.fetch!(result, "canonical_status"),
        "outcome" => Map.fetch!(result, "outcome"),
        "compiled_workflow" => Map.take(artifacts, ~w(
         coding_plan_path
         coding_pipeline_path
         compile_manifest_path
         graph_hash
         compiler_version
       )),
        "steering_history" => controls,
        "validation_outputs" => validation,
        "review_verdict" => review
      }
      |> maybe_put_terminal_descriptor(
        "workspace_release",
        get_in(result, ["artifacts", "workspace_release"])
      )
      |> maybe_put_terminal_descriptor(
        "branch_lifecycle",
        get_in(result, ["artifacts", "branch_lifecycle"])
      )
      |> maybe_put_terminal_descriptor(
        "verification_report",
        Map.get(result, "verification_report")
      )
      |> maybe_put_terminal_candidate(result, task_id)

    case maybe_put_archived_metrics(body, result) do
      {:ok, body} -> {:ok, body}
      {:error, _reason} = error -> error
    end
  end

  defp maybe_put_terminal_candidate(body, result, task_id) do
    candidate = %{
      "task_id" => task_id,
      "workspace_id" => Map.get(result, "workspace_id"),
      "repo_path" => Map.get(result, "repo_path"),
      "branch" => Map.get(result, "branch"),
      "base_commit" => Map.get(result, "base_commit"),
      "candidate_commit" => Map.get(result, "commit_hash") || Map.get(result, "commit"),
      "branch_provenance" => Map.get(result, "branch_provenance"),
      "evidence_ref" => Map.get(result, "evidence_ref")
    }

    if complete_terminal_candidate?(candidate) do
      Map.put(body, "candidate", candidate)
    else
      body
    end
  end

  defp complete_terminal_candidate?(candidate) do
    Enum.all?(
      ~w(task_id workspace_id repo_path branch base_commit candidate_commit branch_provenance evidence_ref),
      fn key ->
        value = Map.get(candidate, key)
        is_binary(value) and String.valid?(value) and String.trim(value) != ""
      end
    )
  end

  defp maybe_put_archived_metrics(body, result) do
    case Map.fetch(result, "metrics") do
      :error ->
        {:ok, body}

      {:ok, metrics} ->
        case sanitize_archived_metrics(metrics) do
          {:ok, sanitized} -> {:ok, Map.put(body, "metrics", sanitized)}
          {:error, _reason} = error -> error
        end
    end
  end

  defp validate_terminal_metrics(nil), do: :ok

  defp validate_terminal_metrics(metrics) do
    case sanitize_archived_metrics(metrics) do
      {:ok, _sanitized} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp sanitize_archived_metrics(metrics) when is_map(metrics) and not is_struct(metrics) do
    with :ok <- validate_json_object(metrics, :invalid_terminal_metrics),
         :ok <- validate_terminal_keys(metrics, @archived_metrics_keys, :terminal_metrics) do
      sanitize_metrics_fields(metrics)
    end
  end

  defp sanitize_archived_metrics(_metrics),
    do: {:error, {:invalid_terminal_metrics, :expected_map}}

  defp sanitize_metrics_fields(metrics) do
    Enum.reduce_while(metrics, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case sanitize_metric_field(key, value) do
        {:ok, sanitized} -> {:cont, {:ok, Map.put(acc, key, sanitized)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp sanitize_metric_field("node_durations_ms", value)
       when is_map(value) and not is_struct(value) do
    with :ok <- validate_json_object(value, :invalid_terminal_metrics),
         true <-
           Enum.all?(value, fn {node_id, duration} ->
             is_binary(node_id) and is_integer(duration) and duration >= 0
           end) do
      bounded =
        value
        |> Enum.sort_by(fn {node_id, duration} -> {node_id, duration} end)
        |> Enum.take(@max_archived_node_durations)
        |> Map.new()

      {:ok, bounded}
    else
      false -> {:error, {:invalid_terminal_metrics, "node_durations_ms"}}
      {:error, _reason} = error -> error
    end
  end

  defp sanitize_metric_field("node_durations_ms", _value),
    do: {:error, {:invalid_terminal_metrics, "node_durations_ms"}}

  defp sanitize_metric_field("usage", value) when is_map(value) and not is_struct(value) do
    with :ok <- validate_json_object(value, :invalid_terminal_metrics) do
      numbers =
        value
        |> Enum.filter(fn {key, number} -> is_binary(key) and is_number(number) end)
        |> Map.new()

      {:ok, numbers}
    end
  end

  defp sanitize_metric_field("usage", _value),
    do: {:error, {:invalid_terminal_metrics, "usage"}}

  defp sanitize_metric_field("completed_nodes", value) when is_list(value) do
    if Enum.all?(value, &(is_binary(&1) and String.valid?(&1))),
      do: {:ok, value},
      else: {:error, {:invalid_terminal_metrics, "completed_nodes"}}
  end

  defp sanitize_metric_field("completed_nodes", _value),
    do: {:error, {:invalid_terminal_metrics, "completed_nodes"}}

  defp sanitize_metric_field(key, value)
       when key in ~w(
         wall_clock_ms
         completed_node_count
         validation_attempts
         review_attempts
         protocol_retry_count
         design_rework_count
         validation_rework_count
         review_rework_count
         operator_rework_count
         total_rework_count
         context_tokens
       ) do
    if is_integer(value) and value >= 0,
      do: {:ok, value},
      else: {:error, {:invalid_terminal_metrics, key}}
  end

  defp sanitize_metric_field(key, value)
       when key in ~w(completed_nodes_truncated node_durations_truncated) do
    if is_boolean(value),
      do: {:ok, value},
      else: {:error, {:invalid_terminal_metrics, key}}
  end

  defp sanitize_metric_field(key, value)
       when key in ~w(
         execution_path
         worker_close_status
         workspace_release_status
         workspace_expires_at
       ) do
    if is_binary(value) and String.valid?(value) and String.trim(value) != "",
      do: {:ok, value},
      else: {:error, {:invalid_terminal_metrics, key}}
  end

  defp sanitize_metric_field(key, _value),
    do: {:error, {:invalid_terminal_metrics, key}}

  defp validate_archived_optional_metrics(body) do
    case Map.fetch(body, "metrics") do
      :error ->
        :ok

      {:ok, metrics} ->
        case sanitize_archived_metrics(metrics) do
          {:ok, _sanitized} -> :ok
          {:error, _reason} -> {:error, :invalid_coding_terminal_evidence}
        end
    end
  end

  defp validate_archived_terminal_evidence(body, task_id)
       when is_map(body) and is_binary(task_id) do
    keys = Map.keys(body) |> MapSet.new()
    allowed = MapSet.union(@archived_terminal_required_keys, @archived_terminal_optional_keys)

    with true <- MapSet.subset?(keys, allowed),
         true <- MapSet.subset?(@archived_terminal_required_keys, keys),
         true <- body["schema_version"] === 1,
         true <- body["task_id"] === task_id,
         true <- OutcomeMapper.terminal_status?(body["terminal_status"]),
         true <- OutcomeMapper.terminal_status?(body["canonical_status"]),
         true <-
           OutcomeMapper.compatible_with_status?(body["outcome"], body["canonical_status"]),
         :ok <- validate_archived_compiled_workflow(body["compiled_workflow"]),
         {:ok, _controls} <-
           TaskTerminalArchiveCore.validate_control_history(task_id, body["steering_history"]),
         :ok <- validate_archived_validation_outputs(body["validation_outputs"]),
         :ok <- validate_archived_review_verdict(body["review_verdict"]),
         :ok <-
           validate_archived_optional_descriptor(
             body,
             "workspace_release",
             WorkspaceReleaseDescriptor
           ),
         :ok <-
           validate_archived_optional_descriptor(
             body,
             "branch_lifecycle",
             BranchLifecycleDescriptor
           ),
         :ok <- validate_archived_optional_verification_report(body),
         :ok <- validate_archived_optional_candidate(body, task_id),
         :ok <- validate_archived_optional_metrics(body) do
      :ok
    else
      _ -> {:error, :invalid_coding_terminal_evidence}
    end
  end

  defp validate_archived_terminal_evidence(_body, _task_id),
    do: {:error, :invalid_coding_terminal_evidence}

  defp validate_archived_compiled_workflow(workflow)
       when is_map(workflow) and not is_struct(workflow) do
    keys = Map.keys(workflow) |> MapSet.new()

    with true <- keys == @compiled_workflow_keys,
         :ok <- validate_terminal_path(workflow["coding_plan_path"]),
         :ok <- validate_terminal_path(workflow["coding_pipeline_path"]),
         :ok <- validate_terminal_path(workflow["compile_manifest_path"]),
         :ok <- validate_terminal_hash(workflow["graph_hash"]),
         :ok <- required_terminal_string(workflow, "compiler_version") |> discard_value() do
      :ok
    else
      _ -> {:error, :invalid_coding_terminal_evidence}
    end
  end

  defp validate_archived_compiled_workflow(_workflow),
    do: {:error, :invalid_coding_terminal_evidence}

  defp validate_archived_validation_outputs(outputs) when is_list(outputs),
    do: validate_json_value(outputs, [])

  defp validate_archived_validation_outputs(_outputs),
    do: {:error, :invalid_coding_terminal_evidence}

  defp validate_archived_review_verdict(review) when is_map(review) and not is_struct(review),
    do: validate_json_object(review, :invalid_terminal_review)

  defp validate_archived_review_verdict(_review),
    do: {:error, :invalid_coding_terminal_evidence}

  defp validate_archived_optional_descriptor(body, key, contract) do
    case Map.fetch(body, key) do
      :error ->
        :ok

      {:ok, value} ->
        if contract.valid?(value), do: :ok, else: {:error, :invalid_coding_terminal_evidence}
    end
  end

  defp validate_archived_optional_verification_report(body) do
    case Map.fetch(body, "verification_report") do
      :error ->
        :ok

      {:ok, report} ->
        if VerificationReport.valid?(report),
          do: :ok,
          else: {:error, :invalid_coding_terminal_evidence}
    end
  end

  defp validate_archived_optional_candidate(body, task_id) do
    case Map.fetch(body, "candidate") do
      :error ->
        :ok

      {:ok, candidate} when is_map(candidate) and not is_struct(candidate) ->
        if complete_terminal_candidate?(candidate) and candidate["task_id"] === task_id do
          :ok
        else
          {:error, :invalid_coding_terminal_evidence}
        end

      _other ->
        {:error, :invalid_coding_terminal_evidence}
    end
  end

  defp terminal_review_verdict(result) do
    result
    |> Map.get("review", %{})
    |> case do
      review when is_map(review) and not is_struct(review) -> review
      _ -> %{}
    end
    |> maybe_put_review_projection(result, "recommendation", "review_recommendation")
    |> maybe_put_review_projection(result, "tier_decision", "tier_decision")
    |> maybe_put_review_projection(result, "human_required", "human_required")
    |> maybe_put_review_projection(result, "security_veto", "security_veto")
    |> maybe_put_review_projection(result, "blast_radius", "blast_radius")
  end

  defp maybe_put_review_projection(review, result, review_key, result_key) do
    case {Map.get(review, review_key), Map.get(result, result_key)} do
      {value, _fallback} when not is_nil(value) -> review
      {nil, value} when not is_nil(value) -> Map.put(review, review_key, value)
      _ -> review
    end
  end

  defp validate_terminal_evidence_size(encoded)
       when is_binary(encoded) and byte_size(encoded) <= @max_terminal_evidence_bytes,
       do: :ok

  defp validate_terminal_evidence_size(_encoded),
    do: {:error, {:terminal_evidence_too_large, @max_terminal_evidence_bytes}}

  defp verify_terminal_evidence(path, task_id, expected_bytes) do
    expected_digest = sha256(expected_bytes)

    with {:ok, %File.Stat{type: :regular, mode: mode}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o777) == 0o600,
         {:ok, bytes} <- read_descriptor_bounded_file(path, @max_terminal_evidence_bytes),
         true <- byte_size(bytes) == byte_size(expected_bytes),
         true <- sha256(bytes) == expected_digest,
         {:ok, descriptor} <-
           TaskEvidenceDescriptor.normalize(%{
             "path" => path,
             "sha256" => expected_digest,
             "byte_size" => byte_size(bytes),
             "schema_version" => 1,
             "task_id" => task_id
           }) do
      {:ok, descriptor}
    else
      false -> {:error, :terminal_evidence_verification_failed}
      {:error, reason} -> {:error, {:terminal_evidence_verification_failed, reason}}
      _ -> {:error, :terminal_evidence_verification_failed}
    end
  end

  defp validate_task_terminal_path(root, path) do
    with true <- Path.dirname(path) == root,
         {:ok, ^path} <- SafePath.resolve_within(path, root),
         {:ok, ^root} <- SafePath.resolve_real(Path.dirname(path)) do
      :ok
    else
      _ -> {:error, :task_terminal_path_escape}
    end
  end

  defp do_reconcile_settled_controls(root, task_id, controls) when is_list(controls) do
    # Classify the existing target with writer-side fail-closed atoms before any
    # recovery-style read. `read_task_terminal/2` collapses symlink, non-regular,
    # and insecure-mode files to :malformed.
    path = Path.join(root, @task_terminal_filename)

    case classify_task_terminal_target(path) do
      :absent ->
        {:ok, controls}

      :present ->
        reconcile_present_task_terminal(path, task_id, controls)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_reconcile_settled_controls(_root, _task_id, _controls),
    do: {:error, {:invalid_terminal_controls, :expected_list}}

  defp reconcile_present_task_terminal(path, task_id, controls) do
    case read_descriptor_bounded_file(path, @max_task_terminal_bytes) do
      {:ok, encoded} ->
        case decode_task_terminal_archive(encoded, task_id) do
          {:ok, archive} ->
            reconcile_existing_settled_controls(archive, controls)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :enoent} ->
        {:ok, controls}

      {:error, :malformed} ->
        {:error, :malformed}

      {:error, _reason} ->
        {:error, :task_terminal_unreadable}
    end
  end

  defp reconcile_existing_settled_controls(archive, controls) when is_map(archive) do
    archived = Map.get(archive, "controls") || []

    cond do
      not is_list(archived) ->
        {:error, :malformed}

      controls == [] ->
        {:ok, archived}

      controls === archived ->
        {:ok, controls}

      true ->
        {:error, :task_terminal_conflict}
    end
  end

  defp reconcile_existing_settled_controls(_archive, _controls),
    do: {:error, :malformed}

  defp classify_task_terminal_target(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :absent

      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        if Bitwise.band(mode, 0o777) != 0o600 do
          {:error, :insecure_task_terminal_mode}
        else
          :present
        end

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :task_terminal_symlink}

      {:ok, _other} ->
        {:error, :invalid_task_terminal_file}

      {:error, _reason} ->
        {:error, :task_terminal_unavailable}
    end
  end

  defp write_task_terminal_once(path, content, root) do
    case classify_task_terminal_target(path) do
      :absent ->
        write_task_terminal_new(path, content, root)

      :present ->
        case read_descriptor_bounded_file(path, @max_task_terminal_bytes) do
          {:ok, ^content} -> :ok
          {:ok, _other} -> {:error, :task_terminal_conflict}
          {:error, :malformed} -> {:error, :task_terminal_conflict}
          {:error, _reason} -> {:error, :task_terminal_unreadable}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_terminal_evidence_once(path, content, root) do
    case File.lstat(path) do
      {:error, :enoent} ->
        write_terminal_evidence_new(path, content, root)

      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        cond do
          Bitwise.band(mode, 0o777) != 0o600 ->
            {:error, :insecure_mode}

          true ->
            case read_descriptor_bounded_file(path, @max_terminal_evidence_bytes) do
              {:ok, ^content} -> :ok
              {:ok, _other} -> {:error, :terminal_evidence_conflict}
              {:error, :malformed} -> {:error, :terminal_evidence_conflict}
              {:error, _reason} -> {:error, :terminal_evidence_unreadable}
            end
        end

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :terminal_evidence_symlink}

      {:ok, _other} ->
        {:error, :invalid_terminal_evidence_file}

      {:error, _reason} ->
        {:error, :terminal_evidence_unavailable}
    end
  end

  defp write_terminal_evidence_new(path, content, root) do
    temporary_path = temporary_path(path)

    try do
      with :ok <- validate_task_terminal_path(root, path),
           {:ok, %File.Stat{type: :directory}} <- File.lstat(root),
           :ok <- write_secure_temp(temporary_path, content),
           :ok <- File.ln(temporary_path, path) do
        :ok
      else
        {:error, :eexist} -> write_terminal_evidence_once(path, content, root)
        {:error, reason} -> {:error, {:write_artifact_failed, Path.basename(path), reason}}
        _other -> {:error, {:write_artifact_failed, Path.basename(path), :failed}}
      end
    after
      File.rm(temporary_path)
    end
  end

  defp write_task_terminal_new(path, content, root) do
    temporary_path = temporary_path(path)

    try do
      with :ok <- validate_task_terminal_path(root, path),
           {:ok, %File.Stat{type: :directory}} <- File.lstat(root),
           :ok <- write_secure_temp(temporary_path, content),
           :ok <- File.ln(temporary_path, path) do
        :ok
      else
        {:error, :eexist} -> write_task_terminal_once(path, content, root)
        {:error, _reason} -> {:error, :write_task_terminal_failed}
        _other -> {:error, :write_task_terminal_failed}
      end
    after
      File.rm(temporary_path)
    end
  end

  defp write_closed_artifact_once(path, content, root, kind) do
    max_bytes = closed_artifact_max_bytes_for_kind(kind)

    case File.lstat(path) do
      {:error, :enoent} ->
        write_closed_artifact_new(path, content, root, kind)

      {:ok, %File.Stat{type: :regular, mode: mode, size: size} = first} ->
        cond do
          Bitwise.band(mode, 0o777) != 0o600 ->
            {:error, :insecure_mode}

          not is_integer(size) or size < 0 or size > max_bytes ->
            {:error, :malformed}

          true ->
            compare_closed_artifact_duplicate(path, content, first, max_bytes)
        end

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :malformed}

      {:ok, _} ->
        {:error, :malformed}

      {:error, :eio} ->
        {:error, :unavailable}

      {:error, _} ->
        {:error, :unavailable}
    end
  end

  defp compare_closed_artifact_duplicate(path, content, first, max_bytes) do
    case read_descriptor_bounded_file(path, max_bytes) do
      {:ok, encoded} ->
        case File.lstat(path) do
          {:ok, %File.Stat{type: :regular, mode: mode, size: size}} ->
            cond do
              Bitwise.band(mode, 0o777) != 0o600 ->
                {:error, :insecure_mode}

              size != first.size or Bitwise.band(first.mode, 0o777) != Bitwise.band(mode, 0o777) ->
                {:error, :malformed}

              byte_size(encoded) != size ->
                {:error, :malformed}

              encoded == content ->
                :ok

              true ->
                {:error, :stale_or_duplicate_terminal}
            end

          {:ok, _} ->
            {:error, :malformed}

          {:error, :eio} ->
            {:error, :unavailable}

          {:error, _} ->
            {:error, :unavailable}
        end

      {:error, :enoent} ->
        {:error, :unavailable}

      {:error, :eio} ->
        {:error, :unavailable}

      {:error, :malformed} ->
        {:error, :malformed}

      {:error, _} ->
        {:error, :unavailable}
    end
  end

  defp write_closed_artifact_new(path, content, root, kind) do
    temporary_path = temporary_path(path)

    try do
      with :ok <- validate_task_terminal_path(root, path),
           {:ok, %File.Stat{type: :directory}} <- File.lstat(root),
           :ok <- write_secure_temp(temporary_path, content),
           :ok <- File.ln(temporary_path, path) do
        :ok
      else
        {:error, :eexist} -> write_closed_artifact_once(path, content, root, kind)
        {:error, :eio} -> {:error, :unavailable}
        {:error, _} -> {:error, :unavailable}
        _ -> {:error, :unavailable}
      end
    after
      File.rm(temporary_path)
    end
  end

  defp read_closed_artifact(root, filename, validate_fun)
       when is_binary(root) and is_binary(filename) and is_function(validate_fun, 1) do
    with {:ok, root} <- normalize_existing_root(root),
         path = Path.join(root, filename),
         :ok <- validate_task_terminal_path(root, path),
         max_bytes = closed_artifact_max_bytes(filename) do
      case read_descriptor_bounded_file(path, max_bytes) do
        {:ok, encoded} ->
          case Jason.decode(encoded) do
            {:ok, map} when is_map(map) and not is_struct(map) ->
              case {CodingRunRecoveryCore.canonical_json(map), validate_fun.(map)} do
                {{:ok, _}, :ok} -> {:ok, map}
                _ -> {:error, :malformed}
              end

            _ ->
              {:error, :malformed}
          end

        {:error, :enoent} ->
          {:error, :not_found}

        {:error, :eio} ->
          {:error, :unavailable}

        {:error, :malformed} ->
          {:error, :malformed}

        {:error, _} ->
          {:error, :unavailable}
      end
    else
      {:error, :eio} -> {:error, :unavailable}
      {:error, _} -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp closed_artifact_max_bytes(@run_binding_filename), do: @max_run_binding_bytes
  defp closed_artifact_max_bytes(@engine_terminal_filename), do: @max_engine_terminal_bytes
  defp closed_artifact_max_bytes(@adapter_input_filename), do: @max_adapter_input_bytes
  defp closed_artifact_max_bytes(@terminal_decision_filename), do: @max_terminal_decision_bytes
  defp closed_artifact_max_bytes(_), do: @max_engine_terminal_bytes

  defp closed_artifact_max_bytes_for_kind(:run_binding), do: @max_run_binding_bytes
  defp closed_artifact_max_bytes_for_kind(:engine_terminal), do: @max_engine_terminal_bytes
  defp closed_artifact_max_bytes_for_kind(:adapter_input), do: @max_adapter_input_bytes
  defp closed_artifact_max_bytes_for_kind(:terminal_decision), do: @max_terminal_decision_bytes
  defp closed_artifact_max_bytes_for_kind(_), do: @max_engine_terminal_bytes

  defp validate_encoded_size(encoded, max)
       when is_binary(encoded) and is_integer(max) and max > 0 do
    if byte_size(encoded) > 0 and byte_size(encoded) <= max,
      do: :ok,
      else: {:error, :malformed}
  end

  defp validate_encoded_size(_encoded, _max), do: {:error, :malformed}

  @doc """
  Read one regular mode-`0600` file with a kind-bounded max-plus-one double read.

  Callers in `CodingTaskExecutor` must invoke this through
  `Config.coding_plan_artifact_store/0`, never as a hardcoded cross-module
  import of this function alone.
  """
  @spec read_descriptor_bounded_file(String.t(), pos_integer()) ::
          {:ok, binary()} | {:error, :enoent | :eio | :malformed | :unavailable}
  def read_descriptor_bounded_file(path, max_bytes)
      when is_binary(path) and is_integer(max_bytes) and max_bytes > 0 do
    case File.lstat(path, time: :posix) do
      {:error, :enoent} ->
        {:error, :enoent}

      {:error, :eio} ->
        {:error, :eio}

      {:ok, %File.Stat{type: :regular, mode: mode} = first} ->
        if Bitwise.band(mode, 0o777) == 0o600 do
          case SafePath.resolve_real(path) do
            {:ok, canonical} ->
              maybe_bounded_read_pre_open_hook(path)
              open_descriptor_double_read(path, canonical, first, max_bytes)

            {:error, :eio} ->
              {:error, :eio}

            _ ->
              {:error, :malformed}
          end
        else
          {:error, :malformed}
        end

      {:ok, _} ->
        {:error, :malformed}

      {:error, _} ->
        {:error, :unavailable}
    end
  end

  defp open_descriptor_double_read(path, canonical, first, max_bytes) do
    case File.open(path, [:read, :raw, :binary]) do
      {:ok, io} ->
        try do
          with :ok <- require_descriptor_identity(io, first),
               {:ok, first_bytes} <- read_max_plus_one(io, max_bytes),
               :ok <- require_descriptor_identity(io, first, byte_size(first_bytes)),
               :ok <- postcheck_path_inode(path, canonical, first, first_bytes),
               :ok <- rewind_descriptor_fd(io),
               {:ok, second_bytes} <- read_max_plus_one(io, max_bytes),
               true <- first_bytes == second_bytes,
               :ok <- require_descriptor_identity(io, first, byte_size(second_bytes)),
               :ok <- postcheck_path_inode(path, canonical, first, second_bytes) do
            {:ok, first_bytes}
          else
            false -> {:error, :malformed}
            {:error, _} = error -> error
            _ -> {:error, :malformed}
          end
        after
          File.close(io)
        end

      {:error, :enoent} ->
        {:error, :enoent}

      {:error, :eio} ->
        {:error, :eio}

      {:error, _} ->
        {:error, :unavailable}
    end
  end

  defp maybe_bounded_read_pre_open_hook(path) when is_binary(path) do
    case Process.get(@bounded_read_pre_open_hook_key) do
      fun when is_function(fun, 1) ->
        _ = fun.(path)
        :ok

      _other ->
        :ok
    end
  end

  defp descriptor_file_stat(io) do
    case :file.read_file_info(io, time: :posix) do
      {:ok, info} -> {:ok, File.Stat.from_record(info)}
      {:error, :eio} -> {:error, :eio}
      {:error, _} -> {:error, :unavailable}
    end
  end

  defp require_descriptor_identity(io, %File.Stat{} = first, expected_size \\ nil) do
    with {:ok, %File.Stat{type: :regular, mode: mode} = stat} <- descriptor_file_stat(io),
         true <- Bitwise.band(mode, 0o777) == 0o600,
         true <- same_file_identity?(stat, first),
         true <- is_nil(expected_size) or stat.size == expected_size do
      :ok
    else
      {:error, :eio} -> {:error, :eio}
      {:error, _} = error -> error
      _ -> {:error, :malformed}
    end
  end

  defp same_file_identity?(%File.Stat{} = left, %File.Stat{} = right) do
    left.inode == right.inode and left.major_device == right.major_device and
      left.minor_device == right.minor_device
  end

  defp read_max_plus_one(io, max_bytes) do
    case IO.binread(io, max_bytes + 1) do
      :eof ->
        {:error, :malformed}

      {:error, :eio} ->
        {:error, :eio}

      {:error, _} ->
        {:error, :unavailable}

      bytes when is_binary(bytes) and byte_size(bytes) > max_bytes ->
        {:error, :malformed}

      bytes when is_binary(bytes) and byte_size(bytes) == 0 ->
        {:error, :malformed}

      bytes when is_binary(bytes) ->
        {:ok, bytes}

      _ ->
        {:error, :unavailable}
    end
  end

  defp rewind_descriptor_fd(io) do
    case :file.position(io, :bof) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :unavailable}
    end
  end

  defp postcheck_path_inode(path, canonical, %File.Stat{} = first, bytes)
       when is_binary(path) and is_binary(canonical) and is_binary(bytes) do
    with {:ok, ^canonical} <- SafePath.resolve_real(path),
         {:ok, %File.Stat{type: :regular, mode: mode, size: size} = stat} <-
           File.lstat(path, time: :posix),
         true <- Bitwise.band(mode, 0o777) == 0o600,
         true <- same_file_identity?(stat, first),
         true <- size == byte_size(bytes) do
      :ok
    else
      {:error, :eio} -> {:error, :eio}
      _ -> {:error, :malformed}
    end
  end

  defp decode_task_terminal_archive(encoded, task_id) when is_binary(encoded) do
    with {:ok, body} <- Jason.decode(encoded),
         true <- is_map(body) and not is_struct(body),
         true <- body["schema_version"] == 1,
         true <- body["task_id"] == task_id,
         envelope when is_map(envelope) and not is_struct(envelope) <-
           body["terminal_envelope"],
         {:ok, _archive} <-
           TaskTerminalArchiveCore.build(task_id, envelope, body["controls"] || []) do
      {:ok, body}
    else
      _ -> {:error, :malformed}
    end
  rescue
    _ -> {:error, :malformed}
  catch
    _, _ -> {:error, :malformed}
  end

  defp verify_task_terminal(path, archive) do
    expected_descriptor = Map.put(archive.descriptor_fields, "path", path)

    with {:ok, %File.Stat{type: :regular, mode: mode}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o777) == 0o600,
         {:ok, bytes} <- read_descriptor_bounded_file(path, @max_task_terminal_bytes),
         true <- bytes === archive.encoded,
         {:ok, body} <- Jason.decode(bytes),
         true <- body === archive.body do
      {:ok, expected_descriptor}
    else
      _ -> {:error, :task_terminal_verification_failed}
    end
  end

  # The content-addressed name makes exact replay idempotent. TaskStore
  # serializes adoption for one task; distinct observations remain distinct
  # evidence files instead of overwriting an earlier proof.
  defp write_adoption_evidence_once(path, encoded) do
    case File.lstat(path) do
      {:error, :enoent} ->
        atomic_write(path, encoded)

      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        with true <- Bitwise.band(mode, 0o777) == 0o600,
             {:ok, ^encoded} <- File.read(path) do
          :ok
        else
          false -> {:error, :insecure_adoption_evidence_mode}
          {:ok, _other} -> {:error, :adoption_evidence_conflict}
          {:error, reason} -> {:error, {:adoption_evidence_unreadable, reason}}
        end

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :adoption_evidence_symlink}

      {:ok, _other} ->
        {:error, :invalid_adoption_evidence_file}

      {:error, reason} ->
        {:error, {:adoption_evidence_unavailable, reason}}
    end
  end

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp validate_dot_source(dot_source) when is_binary(dot_source) and byte_size(dot_source) > 0,
    do: :ok

  defp validate_dot_source(_dot_source),
    do: {:error, {:invalid_dot_source, :expected_non_empty_binary}}

  defp validate_json_object(value, error_tag) when is_map(value) and not is_struct(value) do
    case validate_json_map(value, []) do
      :ok -> :ok
      {:error, reason} -> {:error, {error_tag, reason}}
    end
  end

  defp validate_json_object(_value, error_tag),
    do: {:error, {error_tag, :expected_string_keyed_map}}

  defp validate_json_map(map, path) do
    Enum.reduce_while(map, :ok, fn {key, value}, :ok ->
      if is_binary(key) do
        case validate_json_value(value, [key | path]) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      else
        {:halt, {:error, {:non_string_key, Enum.reverse(path)}}}
      end
    end)
  end

  defp validate_json_value(value, _path)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: :ok

  defp validate_json_value(value, path) when is_list(value),
    do: validate_json_list(value, path, 0)

  defp validate_json_value(value, path) when is_map(value) and not is_struct(value),
    do: validate_json_map(value, path)

  defp validate_json_value(%_struct{}, path),
    do: {:error, {:struct_not_json, Enum.reverse(path)}}

  defp validate_json_value(_value, path),
    do: {:error, {:non_json_value, Enum.reverse(path)}}

  defp validate_json_list([], _path, _index), do: :ok

  defp validate_json_list([head | tail], path, index) do
    with :ok <- validate_json_value(head, [index | path]) do
      validate_json_list(tail, path, index + 1)
    end
  end

  defp validate_json_list(_improper_tail, path, index),
    do: {:error, {:improper_list, Enum.reverse([index | path])}}

  defp fetch_manifest_string(manifest, key) do
    case Map.fetch(manifest, key) do
      {:ok, value} when is_binary(value) ->
        if String.valid?(value) and String.trim(value) != "" do
          {:ok, value}
        else
          {:error, {:invalid_manifest_field, key}}
        end

      _ ->
        {:error, {:invalid_manifest_field, key}}
    end
  end

  defp encode_json(value, artifact) do
    case Jason.encode(value, pretty: true) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, reason} -> {:error, {:json_encode_failed, artifact, Exception.message(reason)}}
    end
  rescue
    error -> {:error, {:json_encode_failed, artifact, Exception.message(error)}}
  end

  defp encode_canonical_json(value, artifact) do
    with {:ok, canonical} <- CodingRunRecoveryCore.canonical_json(value),
         {:ok, encoded} <- Jason.encode(canonical, pretty: true) do
      {:ok, encoded}
    else
      {:error, :invalid_json} ->
        {:error, {:json_encode_failed, artifact, "invalid_json"}}

      {:error, reason} ->
        {:error, {:json_encode_failed, artifact, Exception.message(reason)}}
    end
  rescue
    error -> {:error, {:json_encode_failed, artifact, Exception.message(error)}}
  end

  defp encode_compact_canonical_json(value, artifact) do
    with {:ok, canonical} <- CodingRunRecoveryCore.canonical_json(value),
         {:ok, encoded} <- Jason.encode(canonical) do
      {:ok, encoded}
    else
      {:error, :invalid_json} ->
        {:error, {:json_encode_failed, artifact, "invalid_json"}}

      {:error, reason} ->
        {:error, {:json_encode_failed, artifact, Exception.message(reason)}}
    end
  rescue
    error -> {:error, {:json_encode_failed, artifact, Exception.message(error)}}
  end

  defp create_root(root) do
    case File.mkdir_p(root) do
      :ok -> :ok
      {:error, reason} -> {:error, {:create_artifact_root_failed, reason}}
    end
  end

  defp artifact_paths(root) do
    %{
      coding_plan: Path.join(root, @plan_filename),
      coding_pipeline: Path.join(root, @pipeline_filename),
      compile_manifest: Path.join(root, @manifest_filename)
    }
  end

  defp compilation_seal_path(root), do: Path.join(root, @compilation_seal_filename)

  defp compilation_artifacts(paths, plan_json, dot_source, manifest_json) do
    [
      %{filename: @plan_filename, path: paths.coding_plan, content: plan_json},
      %{filename: @pipeline_filename, path: paths.coding_pipeline, content: dot_source},
      %{filename: @manifest_filename, path: paths.compile_manifest, content: manifest_json}
    ]
  end

  defp validate_compilation_graph_hash(graph_hash, dot_source) do
    if graph_hash == sha256(dot_source),
      do: :ok,
      else: {:error, :compilation_graph_hash_mismatch}
  end

  defp validate_compilation_artifact_sizes(artifacts) do
    Enum.reduce_while(artifacts, :ok, fn artifact, :ok ->
      size = byte_size(artifact.content)

      if size > 0 and size <= @max_compilation_artifact_bytes do
        {:cont, :ok}
      else
        {:halt, {:error, {:compilation_artifact_size_out_of_bounds, artifact.filename}}}
      end
    end)
  end

  defp build_compilation_seal(artifacts) do
    sealed_artifacts =
      Map.new(artifacts, fn artifact ->
        {artifact.filename,
         %{
           "byte_size" => byte_size(artifact.content),
           "sha256" => sha256(artifact.content)
         }}
      end)

    encode_canonical_json(
      %{
        "schema_version" => @compilation_seal_schema_version,
        "artifacts" => sealed_artifacts
      },
      :compilation_seal
    )
  end

  defp publish_compilation_bundle(root, artifacts, seal_json) do
    with :ok <- claim_compilation_seal(root, artifacts, seal_json) do
      Enum.reduce_while(artifacts, :ok, fn artifact, :ok ->
        case write_compilation_artifact(artifact.path, artifact.content) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp claim_compilation_seal(root, artifacts, seal_json) do
    seal_path = compilation_seal_path(root)

    case File.lstat(seal_path) do
      {:error, :enoent} ->
        claim_new_compilation_seal(seal_path, artifacts, seal_json)

      {:ok, _stat} ->
        verify_existing_compilation_seal(seal_path, seal_json)

      {:error, reason} ->
        {:error, {:compilation_seal_unavailable, reason}}
    end
  end

  defp claim_new_compilation_seal(seal_path, artifacts, seal_json) do
    case validate_preseal_compilation_artifacts(artifacts) do
      :ok ->
        publish_new_compilation_seal(seal_path, seal_json)

      {:error, _reason} = preseal_error ->
        resolve_preseal_compilation_error(seal_path, seal_json, preseal_error)
    end
  end

  defp validate_preseal_compilation_artifacts(artifacts) do
    Enum.reduce_while(artifacts, :ok, fn artifact, :ok ->
      case validate_preseal_compilation_artifact(artifact.path, artifact.content) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_preseal_compilation_artifact(path, content) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :regular}} ->
        case equal_compilation_bytes(path, content, @max_compilation_artifact_bytes) do
          :ok ->
            :ok

          :conflict ->
            {:error, {:compilation_artifact_conflict, Path.basename(path)}}

          :invalid ->
            {:error, {:invalid_compilation_artifact, Path.basename(path)}}

          other ->
            {:error, {:compilation_artifact_unreadable, Path.basename(path), other}}
        end

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, {:compilation_artifact_symlink, Path.basename(path)}}

      {:ok, _other} ->
        {:error, {:invalid_compilation_artifact, Path.basename(path)}}

      {:error, reason} ->
        {:error, {:compilation_artifact_unavailable, Path.basename(path), reason}}
    end
  end

  defp resolve_preseal_compilation_error(seal_path, seal_json, preseal_error) do
    case File.lstat(seal_path) do
      {:error, :enoent} ->
        preseal_error

      {:ok, _stat} ->
        case verify_existing_compilation_seal(seal_path, seal_json) do
          :ok -> preseal_error
          {:error, _reason} = error -> error
        end

      {:error, reason} ->
        {:error, {:compilation_seal_unavailable, reason}}
    end
  end

  defp publish_new_compilation_seal(path, seal_json) do
    temporary_path = temporary_path(path)

    publication =
      try do
        with :ok <- write_secure_temp(temporary_path, seal_json),
             :ok <- maybe_wait_for_compilation_publication(:before_compilation_seal_link),
             :ok <- File.ln(temporary_path, path) do
          :published
        else
          {:error, :eexist} -> :existing
          {:error, reason} -> {:error, {:write_artifact_failed, Path.basename(path), reason}}
        end
      after
        File.rm(temporary_path)
      end

    case publication do
      :published ->
        maybe_wait_for_compilation_publication(:after_compilation_seal_link)

      :existing ->
        verify_existing_compilation_seal(path, seal_json)

      {:error, _reason} = error ->
        error
    end
  end

  defp verify_existing_compilation_seal(path, seal_json) do
    case equal_compilation_bytes(path, seal_json, @max_compilation_seal_bytes) do
      :ok -> :ok
      :conflict -> {:error, :compilation_seal_conflict}
      :missing -> {:error, :compilation_seal_missing}
      :invalid -> {:error, :invalid_compilation_seal}
      :eio -> {:error, {:compilation_seal_unavailable, :eio}}
      other -> {:error, {:compilation_seal_unreadable, other}}
    end
  end

  defp write_compilation_artifact(path, content) do
    case File.lstat(path) do
      {:error, :enoent} ->
        write_new_compilation_artifact(path, content)

      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        if Bitwise.band(mode, 0o777) == 0o600 do
          case equal_compilation_bytes(path, content, @max_compilation_artifact_bytes) do
            :ok ->
              :ok

            :conflict ->
              {:error, {:compilation_artifact_conflict, Path.basename(path)}}

            :invalid ->
              {:error, {:invalid_compilation_artifact, Path.basename(path)}}

            other ->
              {:error, {:compilation_artifact_unreadable, Path.basename(path), other}}
          end
        else
          repair_compilation_artifact_mode(path, content)
        end

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, {:compilation_artifact_symlink, Path.basename(path)}}

      {:ok, _other} ->
        {:error, {:invalid_compilation_artifact, Path.basename(path)}}

      {:error, reason} ->
        {:error, {:compilation_artifact_unavailable, Path.basename(path), reason}}
    end
  end

  defp write_new_compilation_artifact(path, content) do
    temporary_path = temporary_path(path)
    filename = Path.basename(path)

    publication =
      try do
        with :ok <- write_secure_temp(temporary_path, content),
             :ok <-
               maybe_wait_for_compilation_publication(
                 {:before_compilation_artifact_link, filename}
               ),
             :ok <- File.ln(temporary_path, path) do
          :published
        else
          {:error, :eexist} -> :existing
          {:error, reason} -> {:error, {:write_artifact_failed, filename, reason}}
        end
      after
        File.rm(temporary_path)
      end

    case publication do
      :published ->
        maybe_wait_for_compilation_publication({:after_compilation_artifact_link, filename})

      :existing ->
        write_compilation_artifact(path, content)

      {:error, _reason} = error ->
        error
    end
  end

  defp repair_compilation_artifact_mode(path, content) do
    with :ok <- File.chmod(path, 0o600),
         {:ok, %File.Stat{type: :regular, mode: mode}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o777) == 0o600,
         :ok <- equal_compilation_bytes(path, content, @max_compilation_artifact_bytes) do
      :ok
    else
      false ->
        {:error, {:invalid_compilation_artifact, Path.basename(path)}}

      :conflict ->
        {:error, {:compilation_artifact_conflict, Path.basename(path)}}

      :invalid ->
        {:error, {:invalid_compilation_artifact, Path.basename(path)}}

      {:error, reason} ->
        {:error, {:compilation_artifact_unavailable, Path.basename(path), reason}}

      _other ->
        {:error, {:invalid_compilation_artifact, Path.basename(path)}}
    end
  end

  defp equal_compilation_bytes(path, expected, max_bytes)
       when is_binary(path) and is_binary(expected) and is_integer(max_bytes) and max_bytes > 0 do
    case read_descriptor_bounded_file(path, max_bytes) do
      {:ok, ^expected} -> :ok
      {:ok, _other} -> :conflict
      {:error, :enoent} -> :missing
      {:error, :eio} -> :eio
      {:error, :malformed} -> :invalid
      {:error, _} -> :unavailable
    end
  end

  defp equal_compilation_bytes(_path, _expected, _max_bytes), do: :invalid

  # Tests use this timing-only process-local barrier to force publication races.
  # It cannot change bytes, identity checks, or publication outcomes.
  defp maybe_wait_for_compilation_publication(stage) do
    case Process.get(@compilation_publication_barrier_key) do
      {owner, ^stage} when is_pid(owner) ->
        send(owner, {:artifact_store_compilation_barrier, self(), stage})

        receive do
          {:artifact_store_compilation_continue, ^stage} -> :ok
        end

      _other ->
        :ok
    end
  end

  defp maybe_wait_for_static_receipt_publication(stage) do
    case Process.get(@static_receipt_publication_barrier_key) do
      {owner, ^stage} when is_pid(owner) ->
        send(owner, {:artifact_store_static_receipt_barrier, self(), stage})

        receive do
          {:artifact_store_static_receipt_continue, ^stage} -> :ok
        end

      _other ->
        :ok
    end
  end

  defp verify_published_static_receipt(base_root, task_id, continuation_id, expected_digest) do
    case read_cross_app_task_static_receipt(
           base_root,
           task_id,
           continuation_id,
           expected_digest
         ) do
      {:ok, %{"descriptor" => descriptor}} ->
        {:ok, descriptor}

      {:error, :cross_app_static_receipt_unavailable} ->
        {:error, :static_receipt_verification_failed}

      {:error, _reason} = error ->
        error
    end
  end

  defp load_and_admit_static_receipt(base_root, task_id) do
    with {:ok, base_root} <- normalize_compilation_base(base_root),
         {:ok, task_root} <- compilation_task_root(base_root, task_id),
         path = Path.join(task_root, @static_receipt_filename),
         :ok <- validate_static_receipt_path(task_root, path),
         {:ok, max_bytes} <- static_receipt_max_json_bytes(),
         {:ok, encoded} <- read_static_receipt_file(path, task_root, max_bytes),
         {:ok, decoded} <- Jason.decode(encoded),
         {:ok, admitted} <-
           Actions.coding_cross_app_static_receipt_admit(decoded),
         {:ok, digest} <-
           Actions.coding_cross_app_static_receipt_digest(admitted),
         {:ok, canonical} <- encode_compact_canonical_json(admitted, :static_receipt),
         true <- canonical === encoded do
      {:ok, encoded, admitted, digest}
    else
      false -> {:error, :cross_app_static_receipt_unavailable}
      {:error, _reason} = error -> error
      _other -> {:error, :cross_app_static_receipt_unavailable}
    end
  end

  defp read_static_receipt_file(path, task_root, max_bytes) do
    with {:ok, %File.Stat{type: :regular, mode: mode, size: size, links: links}} <-
           File.lstat(path),
         true <- Bitwise.band(mode, 0o777) == 0o600,
         true <- links == 1,
         true <- is_integer(size) and size > 0 and size <= max_bytes,
         {:ok, canonical} <- SafePath.resolve_real(path),
         true <- canonical == path and SafePath.within?(canonical, task_root),
         {:ok, content} <- File.read(canonical),
         true <- byte_size(content) == size do
      {:ok, content}
    else
      _ -> {:error, :cross_app_static_receipt_unavailable}
    end
  end

  defp ensure_static_receipt_task_root(base_root, task_id) do
    with {:ok, base_root} <- normalize_compilation_base(base_root),
         digest = sha256(task_id),
         {:ok, task_root} <- SafePath.safe_join(base_root, "task-" <> digest),
         :ok <- create_root(task_root),
         {:ok, canonical} <- compilation_task_root(base_root, task_id) do
      {:ok, canonical}
    end
  end

  defp validate_static_receipt_path(task_root, path) do
    with true <- Path.basename(path) == @static_receipt_filename,
         true <- Path.dirname(path) == task_root,
         {:ok, ^path} <- SafePath.resolve_within(path, task_root),
         {:ok, ^task_root} <- SafePath.resolve_real(Path.dirname(path)),
         true <- SafePath.within?(path, task_root) do
      :ok
    else
      _ -> {:error, :static_receipt_path_escape}
    end
  rescue
    _ -> {:error, :static_receipt_path_escape}
  end

  defp write_static_receipt_once(path, content, task_root) do
    case File.lstat(path) do
      {:error, :enoent} ->
        write_static_receipt_new(path, content, task_root)

      {:ok, %File.Stat{type: :regular, mode: mode, links: links}} ->
        cond do
          Bitwise.band(mode, 0o777) != 0o600 ->
            {:error, :insecure_static_receipt_mode}

          links != 1 ->
            {:error, :static_receipt_hard_link}

          true ->
            case File.read(path) do
              {:ok, ^content} -> :ok
              {:ok, _other} -> {:error, :static_receipt_conflict}
              {:error, _reason} -> {:error, :write_static_receipt_failed}
            end
        end

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :static_receipt_symlink}

      {:ok, _other} ->
        {:error, :invalid_static_receipt_file}

      {:error, _reason} ->
        {:error, :write_static_receipt_failed}
    end
  end

  defp write_static_receipt_new(path, content, task_root) do
    temporary_path = temporary_path(path)

    publication =
      try do
        with :ok <- validate_static_receipt_path(task_root, path),
             {:ok, %File.Stat{type: :directory}} <- File.lstat(task_root),
             :ok <- write_secure_temp(temporary_path, content),
             :ok <- maybe_wait_for_static_receipt_publication(:before_static_receipt_link),
             :ok <- File.ln(temporary_path, path) do
          :published
        else
          {:error, :eexist} -> :existing
          {:error, _reason} -> {:error, :write_static_receipt_failed}
          _other -> {:error, :write_static_receipt_failed}
        end
      after
        File.rm(temporary_path)
      end

    case publication do
      :published -> :ok
      :existing -> write_static_receipt_once(path, content, task_root)
      {:error, _reason} = error -> error
    end
  end

  defp validate_static_receipt_continuation_id(value)
       when is_binary(value) and byte_size(value) > 0 do
    if String.valid?(value) and String.trim(value) != "" and not String.contains?(value, <<0>>) do
      :ok
    else
      {:error, :invalid_static_receipt_input}
    end
  end

  defp validate_static_receipt_continuation_id(_value),
    do: {:error, :invalid_static_receipt_input}

  defp match_static_receipt_task_id(%{"identities" => %{"task_id" => task_id}}, task_id),
    do: :ok

  defp match_static_receipt_task_id(_admitted, _task_id),
    do: {:error, :static_receipt_task_identity_mismatch}

  defp match_static_receipt_continuation_id(
         %{"continuation_id" => continuation_id},
         continuation_id
       ),
       do: :ok

  defp match_static_receipt_continuation_id(_admitted, _continuation_id),
    do: {:error, :static_receipt_continuation_mismatch}

  defp match_static_receipt_digest(digest, digest), do: :ok

  defp match_static_receipt_digest(_digest, _expected),
    do: {:error, :static_receipt_digest_mismatch}

  defp static_receipt_max_json_bytes do
    case Actions.coding_cross_app_static_receipt_limits() do
      %{"max_static_receipt_json_bytes" => max} when is_integer(max) and max > 0 ->
        {:ok, max}

      _ ->
        {:error, :static_receipt_limits_unavailable}
    end
  end

  defp validate_static_receipt_size(encoded, max_bytes)
       when is_binary(encoded) and is_integer(max_bytes) and max_bytes > 0 do
    size = byte_size(encoded)

    if size > 0 and size <= max_bytes do
      :ok
    else
      {:error, :oversized_static_receipt}
    end
  end

  defp validate_static_receipt_size(_encoded, _max_bytes),
    do: {:error, :oversized_static_receipt}

  defp static_receipt_descriptor(task_id, continuation_id, digest, encoded) do
    %{
      "schema_version" => 1,
      "task_id" => task_id,
      "continuation_id" => continuation_id,
      "receipt_sha256" => digest,
      "byte_size" => byte_size(encoded)
    }
  end

  defp engine_static_receipt_descriptor(task_id, digest, encoded) do
    %{
      "schema_version" => 1,
      "task_id" => task_id,
      "digest" => digest,
      "byte_size" => byte_size(encoded)
    }
  end

  defp engine_static_receipt_path(generation_root, digest),
    do: Path.join(generation_root, digest <> ".json")

  defp ensure_engine_static_receipt_generation_root(task_root) do
    with {:ok, generation_root} <-
           SafePath.safe_join(task_root, @engine_static_receipt_directory),
         :ok <- create_root(generation_root),
         {:ok, canonical} <- SafePath.resolve_real(generation_root),
         true <- canonical == generation_root and SafePath.within?(canonical, task_root),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(canonical) do
      {:ok, canonical}
    else
      _ -> {:error, :static_receipt_path_escape}
    end
  rescue
    _ -> {:error, :static_receipt_path_escape}
  end

  defp validate_engine_static_receipt_path(generation_root, path, digest) do
    with true <- Path.basename(path) == digest <> ".json",
         true <- Path.dirname(path) == generation_root,
         {:ok, ^path} <- SafePath.resolve_within(path, generation_root),
         {:ok, ^generation_root} <- SafePath.resolve_real(Path.dirname(path)),
         true <- SafePath.within?(path, generation_root) do
      :ok
    else
      _ -> {:error, :static_receipt_path_escape}
    end
  rescue
    _ -> {:error, :static_receipt_path_escape}
  end

  defp enforce_engine_static_receipt_generation_limit(generation_root, path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        :ok

      {:error, :enoent} ->
        case count_engine_static_receipt_generations(generation_root) do
          count when is_integer(count) and count < @engine_static_receipt_generation_limit ->
            :ok

          count when is_integer(count) ->
            {:error, :static_receipt_generation_limit}

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, _} ->
        {:error, :invalid_static_receipt_file}

      {:error, _reason} ->
        {:error, :write_static_receipt_failed}
    end
  end

  defp count_engine_static_receipt_generations(generation_root) do
    case File.ls(generation_root) do
      {:ok, names} ->
        names
        |> Enum.filter(&Regex.match?(@digest_filename_regex, &1))
        |> Enum.count(fn name ->
          path = Path.join(generation_root, name)

          case File.lstat(path) do
            {:ok, %File.Stat{type: :regular}} -> true
            _ -> false
          end
        end)

      {:error, _reason} ->
        {:error, :write_static_receipt_failed}
    end
  end

  defp write_engine_static_receipt_once(path, content, generation_root) do
    case File.lstat(path) do
      {:error, :enoent} ->
        write_engine_static_receipt_new(path, content, generation_root)

      {:ok, %File.Stat{type: :regular, mode: mode, links: links}} ->
        cond do
          Bitwise.band(mode, 0o777) != 0o600 ->
            {:error, :insecure_static_receipt_mode}

          links != 1 ->
            {:error, :static_receipt_hard_link}

          true ->
            case File.read(path) do
              {:ok, ^content} -> :ok
              {:ok, _other} -> {:error, :static_receipt_conflict}
              {:error, _reason} -> {:error, :write_static_receipt_failed}
            end
        end

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :static_receipt_symlink}

      {:ok, _other} ->
        {:error, :invalid_static_receipt_file}

      {:error, _reason} ->
        {:error, :write_static_receipt_failed}
    end
  end

  defp write_engine_static_receipt_new(path, content, generation_root) do
    temporary_path = temporary_path(path)

    publication =
      try do
        digest = Path.basename(path, ".json")

        with :ok <- validate_engine_static_receipt_path(generation_root, path, digest),
             {:ok, %File.Stat{type: :directory}} <- File.lstat(generation_root),
             :ok <- write_secure_temp(temporary_path, content),
             :ok <- maybe_wait_for_static_receipt_publication(:before_static_receipt_link),
             :ok <- File.ln(temporary_path, path) do
          :published
        else
          {:error, :eexist} -> :existing
          {:error, _reason} -> {:error, :write_static_receipt_failed}
          _other -> {:error, :write_static_receipt_failed}
        end
      after
        File.rm(temporary_path)
      end

    case publication do
      :published -> :ok
      :existing -> write_engine_static_receipt_once(path, content, generation_root)
      {:error, _reason} = error -> error
    end
  end

  defp verify_published_engine_static_receipt(base_root, task_id, expected_digest) do
    case read_cross_app_static_receipt(base_root, task_id, expected_digest) do
      {:ok, %{"descriptor" => descriptor}} ->
        {:ok, descriptor}

      {:error, :cross_app_static_receipt_unavailable} ->
        {:error, :static_receipt_verification_failed}

      {:error, _reason} = error ->
        error
    end
  end

  defp load_and_admit_engine_static_receipt(base_root, task_id, expected_digest) do
    with {:ok, base_root} <- normalize_compilation_base(base_root),
         {:ok, task_root} <- compilation_task_root(base_root, task_id),
         {:ok, generation_root} <-
           SafePath.safe_join(task_root, @engine_static_receipt_directory),
         {:ok, canonical_root} <- SafePath.resolve_real(generation_root),
         true <-
           canonical_root == generation_root and SafePath.within?(canonical_root, task_root),
         path = engine_static_receipt_path(generation_root, expected_digest),
         :ok <- validate_engine_static_receipt_path(generation_root, path, expected_digest),
         {:ok, max_bytes} <- static_receipt_max_json_bytes(),
         {:ok, encoded} <- read_static_receipt_file(path, generation_root, max_bytes),
         {:ok, decoded} <- Jason.decode(encoded),
         {:ok, admitted} <-
           Actions.coding_cross_app_static_receipt_admit(decoded),
         {:ok, digest} <-
           Actions.coding_cross_app_static_receipt_digest(admitted),
         {:ok, canonical} <- encode_compact_canonical_json(admitted, :static_receipt),
         true <- canonical === encoded do
      {:ok, encoded, admitted, digest}
    else
      false -> {:error, :cross_app_static_receipt_unavailable}
      {:error, _reason} = error -> error
      _other -> {:error, :cross_app_static_receipt_unavailable}
    end
  end

  defp atomic_write(path, content) do
    temporary_path = temporary_path(path)

    try do
      with :ok <- write_secure_temp(temporary_path, content),
           :ok <- File.rename(temporary_path, path) do
        :ok
      else
        {:error, reason} ->
          {:error, {:write_artifact_failed, Path.basename(path), reason}}
      end
    after
      File.rm(temporary_path)
    end
  end

  defp write_secure_temp(path, content) do
    # The file is empty until its final restrictive mode is in place.
    case File.open(path, [:write, :binary, :exclusive], fn device ->
           with :ok <- File.chmod(path, 0o600),
                :ok <- IO.binwrite(device, content) do
             :ok
           end
         end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp temporary_path(path) do
    suffix = System.unique_integer([:positive, :monotonic])
    Path.join(Path.dirname(path), ".#{Path.basename(path)}.tmp-#{suffix}")
  end

  defp design_artifact_path(root, design_attempt)
       when is_binary(root) and is_integer(design_attempt) and design_attempt > 0 do
    Path.join(root, "coding-design-attempt-#{design_attempt}.txt")
  end

  defp validate_design_attempt(attempt)
       when is_integer(attempt) and attempt > 0 and attempt <= 1_000_000,
       do: :ok

  defp validate_design_attempt(_attempt), do: {:error, :invalid_design_attempt}

  defp validate_design_body(design, max_bytes)
       when is_binary(design) and byte_size(design) > 0 and byte_size(design) <= max_bytes do
    if String.valid?(design) and String.trim(design) != "" and not String.contains?(design, <<0>>) do
      :ok
    else
      {:error, :invalid_design_body}
    end
  end

  defp validate_design_body(design, max_bytes)
       when is_binary(design) and byte_size(design) > max_bytes,
       do: {:error, :design_body_too_large}

  defp validate_design_body(_design, _max_bytes), do: {:error, :invalid_design_body}

  defp validate_design_artifact_path(root, path) when is_binary(root) and is_binary(path) do
    with true <- String.starts_with?(path, "/"),
         true <- Path.expand(path) == path,
         true <- Path.dirname(path) == root,
         true <- SafePath.within?(path, root),
         true <- String.starts_with?(Path.basename(path), "coding-design-attempt-"),
         true <- String.ends_with?(Path.basename(path), ".txt") do
      :ok
    else
      _ -> {:error, :design_artifact_path_escaped}
    end
  rescue
    _ -> {:error, :design_artifact_path_escaped}
  end

  defp validate_design_artifact_path(_root, _path), do: {:error, :design_artifact_path_escaped}

  defp immutable_write_design(path, content, root) do
    case File.lstat(path) do
      {:error, :enoent} ->
        immutable_atomic_write_design(path, content, root)

      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        with true <- Bitwise.band(mode, 0o777) == 0o600,
             {:ok, existing} <- File.read(path),
             true <- existing == content do
          :ok
        else
          false -> {:error, :design_artifact_conflict}
          {:error, reason} -> {:error, {:design_artifact_unreadable, reason}}
        end

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :design_artifact_symlink}

      {:ok, _other} ->
        {:error, :invalid_design_artifact_file}

      {:error, reason} ->
        {:error, {:design_artifact_unavailable, reason}}
    end
  end

  defp immutable_atomic_write_design(path, content, root) do
    temporary_path = temporary_path(path)

    try do
      with :ok <- validate_design_artifact_path(root, path),
           :ok <- write_secure_temp(temporary_path, content),
           :ok <- File.ln(temporary_path, path) do
        :ok
      else
        {:error, :eexist} -> immutable_write_design(path, content, root)
        {:error, reason} -> {:error, {:write_design_artifact_failed, reason}}
      end
    after
      File.rm(temporary_path)
    end
  end

  defp verify_design_artifact_file(path, root, task_id, design_attempt, expected_design) do
    with {:ok, design} <-
           read_design_artifact_file(path, root, DesignArtifactDescriptor.max_bytes()),
         true <- design == expected_design,
         digest = sha256(design),
         attrs = %{
           "path" => path,
           "sha256" => digest,
           "byte_size" => byte_size(design),
           "schema_version" => DesignArtifactDescriptor.schema_version(),
           "task_id" => task_id,
           "design_attempt" => design_attempt
         },
         {:ok, descriptor} <- DesignArtifactDescriptor.normalize(attrs) do
      {:ok, descriptor}
    else
      false -> {:error, :design_artifact_verify_failed}
      {:error, _reason} = error -> error
      _ -> {:error, :design_artifact_verify_failed}
    end
  end

  defp read_design_artifact_file(path, root, max_bytes) do
    with :ok <- validate_design_artifact_path(root, path),
         {:ok, %File.Stat{type: :regular, mode: mode, size: size}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o777) == 0o600,
         true <- is_integer(size) and size > 0 and size <= max_bytes,
         {:ok, canonical} <- SafePath.resolve_real(path),
         true <- canonical == path and SafePath.within?(canonical, root),
         {:ok, content} <- File.read(canonical),
         true <- byte_size(content) == size do
      {:ok, content}
    else
      _ -> {:error, :design_artifact_unavailable}
    end
  end
end
