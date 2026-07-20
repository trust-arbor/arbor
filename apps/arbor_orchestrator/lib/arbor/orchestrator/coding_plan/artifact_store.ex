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
    metrics
    workspace_release_status
    workspace_expires_at
    artifacts
  ))

  @terminal_statuses MapSet.new(~w(
    approval_denied
    change_committed
    declined
    human_review_required
    no_changes
    pr_created
    pr_failed
    review_failed
    review_rejected
    review_requires_rework
    rework_exhausted
    validation_failed
  ))

  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Coding.TaskEvidenceDescriptor
  alias Arbor.Orchestrator.CodingPlan.TranscriptStore

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
    required = MapSet.new(~w(status canonical_status artifacts))

    with :ok <- validate_terminal_keys(result, @terminal_result_keys, :terminal_result),
         true <- MapSet.subset?(required, Map.keys(result) |> MapSet.new()),
         {:ok, _status} <- required_terminal_string(result, "status"),
         {:ok, canonical_status} <- required_terminal_string(result, "canonical_status"),
         true <- MapSet.member?(@terminal_statuses, Map.fetch!(result, "status")),
         true <- MapSet.member?(@terminal_statuses, canonical_status),
         :ok <- validate_terminal_artifacts(Map.fetch!(result, "artifacts")),
         :ok <- validate_terminal_optional_data(result) do
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
             MapSet.union(required, MapSet.new(~w(acp_transcript workspace_release)))
           ),
         :ok <- validate_terminal_path(artifacts["coding_plan_path"]),
         :ok <- validate_terminal_path(artifacts["coding_pipeline_path"]),
         :ok <- validate_terminal_path(artifacts["compile_manifest_path"]),
         :ok <- validate_terminal_hash(artifacts["graph_hash"]),
         :ok <- required_terminal_string(artifacts, "compiler_version") |> discard_value() do
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
         :ok <- validate_terminal_review(Map.get(result, "review")) do
      :ok
    end
  end

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

    {:ok,
     %{
       "schema_version" => 1,
       "task_id" => task_id,
       "terminal_status" => Map.fetch!(result, "status"),
       "canonical_status" => Map.fetch!(result, "canonical_status"),
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
     }}
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
