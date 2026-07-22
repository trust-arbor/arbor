defmodule Arbor.Orchestrator.CodingPlan.ArtifactStore do
  @moduledoc """
  Archives the immutable inputs and output of coding-plan compilation.

  The caller supplies the per-task artifact root. Artifact names are fixed here
  and never incorporate plan or task text. Each file is written through a
  same-directory, mode-`0600` temporary file and atomically renamed into place.
  """

  @plan_filename "coding-plan.json"
  @pipeline_filename "coding-pipeline.dot"
  @manifest_filename "coding-compile-manifest.json"
  @terminal_evidence_filename "coding-terminal-evidence.json"
  @adoption_evidence_prefix "coding-adoption-evidence-"
  @reconciliation_directory "coding-reconciliation"
  @max_reconciliation_bytes 1_048_576
  @max_terminal_evidence_bytes 1_048_576
  @max_terminal_controls 100
  @max_terminal_task_id_bytes 512
  @max_terminal_control_bytes 16_384

  @terminal_control_keys MapSet.new(~w(
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

  alias Arbor.Common.SafePath

  alias Arbor.Contracts.Coding.{
    BranchLifecycleDescriptor,
    ReconciliationManifest,
    TaskEvidenceDescriptor,
    ValidationCapacityHandoff,
    WorkspaceReleaseDescriptor
  }

  alias Arbor.Orchestrator.CodingPlan.TranscriptStore
  alias Arbor.Orchestrator.CodingPlan.OutcomeMapper

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
         {:ok, plan_json} <- encode_json(plan, :plan),
         {:ok, manifest_json} <- encode_json(manifest, :manifest),
         :ok <- create_root(root),
         paths = artifact_paths(root),
         :ok <- atomic_write(paths.coding_plan, plan_json),
         :ok <- atomic_write(paths.coding_pipeline, dot_source),
         :ok <- atomic_write(paths.compile_manifest, manifest_json) do
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

  @doc "Archive the closed, deterministic terminal evidence for a coding task."
  @spec archive_terminal_evidence(String.t(), String.t(), map(), list()) ::
          {:ok, map()} | {:error, term()}
  def archive_terminal_evidence(root, task_id, result, controls) do
    with {:ok, root} <- normalize_existing_root(root),
         :ok <- validate_terminal_task_id(task_id),
         :ok <- validate_json_object(result, :invalid_terminal_result),
         :ok <- validate_terminal_result(result),
         {:ok, result} <- normalize_terminal_capacity(result),
         {:ok, result} <- normalize_terminal_descriptors(result),
         {:ok, controls} <- normalize_terminal_controls(controls, task_id),
         {:ok, body} <- build_terminal_evidence(result, task_id, controls),
         {:ok, encoded} <- encode_canonical_json(body, :terminal_evidence),
         :ok <- validate_terminal_evidence_size(encoded),
         path <- Path.join(root, @terminal_evidence_filename),
         :ok <- atomic_write(path, encoded),
         {:ok, descriptor} <- verify_terminal_evidence(path, task_id, encoded) do
      {:ok, descriptor}
    end
  rescue
    exception -> {:error, {:terminal_evidence_error, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:terminal_evidence_throw, {kind, reason}}}
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
    case Jason.encode(canonicalize_json(value), pretty: true) do
      {:ok, encoded} -> {:ok, encoded}
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
    case Jason.encode(canonicalize_json(scope)) do
      {:ok, encoded} -> {:ok, sha256(encoded)}
      {:error, reason} -> {:error, {:invalid_reconciliation_scope, reason}}
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
      :ok
    end
  end

  defp normalize_terminal_capacity(result) do
    if Map.get(result, "status") == "validation_capacity_exceeded" do
      [report] = Map.fetch!(result, "validation")
      test = Map.fetch!(report, "test")

      {:ok, handoff} =
        ValidationCapacityHandoff.normalize(Map.fetch!(test, "capacity_handoff"))

      normalized_test = Map.put(test, "capacity_handoff", handoff)
      normalized_report = Map.put(report, "test", normalized_test)
      {:ok, Map.put(result, "validation", [normalized_report])}
    else
      {:ok, result}
    end
  rescue
    _ -> {:error, {:invalid_terminal_result, :capacity_handoff}}
  end

  defp validate_terminal_capacity_consistency(result) do
    status = Map.get(result, "status")
    canonical_status = Map.get(result, "canonical_status")

    capacity_status? =
      status == "validation_capacity_exceeded" or
        canonical_status == "validation_capacity_exceeded"

    cond do
      capacity_status? and
        status == "validation_capacity_exceeded" and
          canonical_status == "validation_capacity_exceeded" ->
        validate_capacity_terminal_shape(result)

      capacity_status? ->
        {:error, {:invalid_terminal_result, :capacity_status_mismatch}}

      capacity_marker?(Map.get(result, "validation")) ->
        {:error, {:invalid_terminal_result, :capacity_evidence_mismatch}}

      true ->
        :ok
    end
  end

  defp validate_capacity_terminal_shape(result) do
    with [report] <- Map.get(result, "validation"),
         true <- is_map(report) and not is_struct(report),
         "validation_capacity_exceeded" <- Map.get(report, "reason"),
         test when is_map(test) and not is_struct(test) <- Map.get(report, "test"),
         "validation_capacity_exceeded" <- Map.get(test, "reason"),
         handoff when is_map(handoff) and not is_struct(handoff) <-
           Map.get(test, "capacity_handoff"),
         true <- ValidationCapacityHandoff.valid?(handoff) do
      :ok
    else
      _ -> {:error, {:invalid_terminal_result, :capacity_handoff}}
    end
  end

  defp capacity_marker?(value) when is_map(value) and not is_struct(value) do
    Enum.any?(value, fn {key, nested} ->
      key == "capacity_handoff" or
        (key in ~w(reason status canonical_status outcome) and
           nested in ~w(capacity_exceeded validation_capacity_exceeded)) or
        capacity_marker?(nested)
    end)
  end

  defp capacity_marker?(value) when is_list(value), do: Enum.any?(value, &capacity_marker?/1)
  defp capacity_marker?(_value), do: false

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

  defp normalize_terminal_controls(controls, task_id) when is_list(controls) do
    if length(controls) > @max_terminal_controls do
      {:error, {:invalid_terminal_controls, :too_many}}
    else
      Enum.reduce_while(controls, {:ok, {[], MapSet.new(), MapSet.new(), 0}}, fn control,
                                                                                 {:ok,
                                                                                  {acc, ids,
                                                                                   sequences,
                                                                                   previous}} ->
        case validate_terminal_control(control, task_id, ids, sequences, previous) do
          {:ok, id, sequence} ->
            {:cont,
             {:ok,
              {[control | acc], MapSet.put(ids, id), MapSet.put(sequences, sequence), sequence}}}

          {:error, _reason} = error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, {controls, _ids, _sequences, _previous}} -> {:ok, Enum.reverse(controls)}
        {:error, _reason} = error -> error
      end
    end
  end

  defp normalize_terminal_controls(_controls, _task_id),
    do: {:error, {:invalid_terminal_controls, :expected_list}}

  defp validate_terminal_control(control, task_id, ids, sequences, previous)
       when is_map(control) and not is_struct(control) do
    with :ok <-
           validate_bounded_json_object(
             control,
             :invalid_terminal_control,
             @max_terminal_control_bytes
           ),
         true <- MapSet.equal?(Map.keys(control) |> MapSet.new(), @terminal_control_keys),
         {:ok, id} <- required_terminal_string(control, "control_id"),
         {:ok, control_task_id} <- required_terminal_string(control, "task_id"),
         true <- control_task_id == task_id,
         true <- byte_size(id) <= 256,
         true <- not MapSet.member?(ids, id),
         sequence when is_integer(sequence) and sequence > 0 and not is_boolean(sequence) <-
           Map.get(control, "sequence"),
         true <- sequence > previous,
         false <- MapSet.member?(sequences, sequence) do
      {:ok, id, sequence}
    else
      false -> {:error, {:invalid_terminal_control, :identity_or_order}}
      nil -> {:error, {:invalid_terminal_control, :sequence}}
      {:error, _reason} = error -> error
      _ -> {:error, {:invalid_terminal_control, :malformed}}
    end
  end

  defp validate_terminal_control(_control, _task_id, _ids, _sequences, _previous),
    do: {:error, {:invalid_terminal_control, :expected_map}}

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
      |> maybe_put_terminal_candidate(result, task_id)

    {:ok, body}
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

  defp validate_bounded_json_object(value, error_tag, max_bytes)
       when is_map(value) and not is_struct(value) do
    with :ok <- validate_json_object(value, error_tag),
         {:ok, encoded} <- encode_json(value, error_tag),
         true <- byte_size(encoded) <= max_bytes do
      :ok
    else
      false -> {:error, {error_tag, :too_large}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_bounded_json_object(_value, error_tag, _max_bytes),
    do: {:error, {error_tag, :expected_map}}

  defp validate_terminal_evidence_size(encoded)
       when is_binary(encoded) and byte_size(encoded) <= @max_terminal_evidence_bytes,
       do: :ok

  defp validate_terminal_evidence_size(_encoded),
    do: {:error, {:terminal_evidence_too_large, @max_terminal_evidence_bytes}}

  defp verify_terminal_evidence(path, task_id, expected_bytes) do
    expected_digest = sha256(expected_bytes)

    with {:ok, %File.Stat{type: :regular, mode: mode}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o777) == 0o600,
         {:ok, bytes} <- File.read(path),
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
    value
    |> canonicalize_json()
    |> Jason.encode(pretty: true)
    |> case do
      {:ok, encoded} -> {:ok, encoded}
      {:error, reason} -> {:error, {:json_encode_failed, artifact, Exception.message(reason)}}
    end
  rescue
    error -> {:error, {:json_encode_failed, artifact, Exception.message(error)}}
  end

  defp canonicalize_json(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, canonicalize_json(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonicalize_json(list) when is_list(list), do: Enum.map(list, &canonicalize_json/1)
  defp canonicalize_json(value), do: value

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
end
