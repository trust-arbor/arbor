defmodule Arbor.Actions.Coding.DesignCheckpoint do
  @moduledoc """
  Shared validation and binding helpers for the durable CodingPlan v2 design
  checkpoint actions.

  The public action modules below are pipeline-internal syscalls. The request
  id is derived from the exact, normalized evidence and is never accepted as
  authority supplied by a caller.
  """

  alias Arbor.Contracts.Coding.DesignArtifactDescriptor
  alias Arbor.Contracts.Coding.WorkPacket

  @max_design_bytes DesignArtifactDescriptor.max_bytes()
  @max_identifier_bytes 256
  @max_task_bytes 16_384
  @max_terminal_response_bytes 65_536
  @max_json_scan_attempts 128
  # Operator-facing description is short prose only. Exact work packet, task,
  # and design evidence live in metadata. Aggregate durable size authority is
  # solely `Arbor.Comms.validate_durable_interaction_payload/1` — do not copy
  # Comms description/metadata ceilings here.
  @max_operator_prose_bytes 1_024
  @default_timeout 60_000
  @max_timeout 3_600_000
  @request_prefix "irq_design_"
  @design_envelope_keys ~w(design design_digest)
  # Legacy inline evidence — request_id algorithm is byte-for-byte stable when
  # `design_artifact` is absent.
  @legacy_evidence_keys ~w(
    task_id
    task
    plan_fingerprint
    workspace_id
    worker_session_id
    provider_session_id
    design_attempt
    packet_digest
    design
    design_digest
  )
  # Artifact-backed evidence — durable path carries descriptor + digest only.
  @artifact_evidence_keys ~w(
    task_id
    task
    plan_fingerprint
    workspace_id
    worker_session_id
    provider_session_id
    design_attempt
    packet_digest
    design_artifact
    design_digest
  )

  @doc false
  def max_design_bytes, do: @max_design_bytes

  @doc false
  def max_task_bytes, do: @max_task_bytes

  @doc false
  def max_terminal_response_bytes, do: @max_terminal_response_bytes

  @doc false
  def max_json_scan_attempts, do: @max_json_scan_attempts

  @doc false
  def build_binding(params, context) when is_map(params) and is_map(context) do
    with {:ok, common} <- build_common_binding(params, context),
         {:ok, design_fields, path} <- design_evidence_fields(params, context) do
      base_evidence =
        Map.merge(
          %{
            "task_id" => common.task_id,
            "task" => common.task,
            "plan_fingerprint" => common.plan_fingerprint,
            "workspace_id" => common.workspace_id,
            "worker_session_id" => common.worker_session_id,
            "provider_session_id" => common.provider_session_id,
            "design_attempt" => common.design_attempt,
            "packet_digest" => common.packet_digest
          },
          design_fields
        )

      with {:ok, request_id} <- request_id(base_evidence),
           {:ok, description} <-
             description(
               common.task_id,
               common.design_attempt,
               common.packet_digest,
               design_fields["design_digest"]
             ),
           {:ok, metadata} <- metadata(base_evidence, common.packet) do
        {:ok,
         %{
           agent_id: context_agent_id(params, context),
           task_id: common.task_id,
           design_attempt: common.design_attempt,
           packet: common.packet,
           path: path,
           base_evidence: base_evidence,
           evidence: Map.put(base_evidence, "request_id", request_id),
           request_id: request_id,
           description: description,
           metadata: metadata,
           design_digest: design_fields["design_digest"],
           design_artifact: Map.get(design_fields, "design_artifact"),
           design: Map.get(design_fields, "design")
         }}
      end
    end
  end

  def build_binding(_params, _context), do: {:error, :invalid_design_checkpoint_input}

  @doc false
  def build_common_binding(params, context) when is_map(params) and is_map(context) do
    with {:ok, work_packet_input} <- required(params, context, :work_packet, :work_packet),
         {:ok, packet} <- normalize_work_packet(work_packet_input),
         :ok <- require_design_policy(packet),
         {:ok, supplied_packet_digest} <- packet_digest_input(params, context),
         {:ok, packet_digest} <- validate_packet_digest(packet, supplied_packet_digest),
         {:ok, task_id} <- required_identifier(params, context, :task_id),
         {:ok, task} <- required_task(params, context),
         {:ok, plan_fingerprint} <- plan_fingerprint_input(params, context),
         {:ok, workspace_id} <- required_identifier(params, context, :workspace_id),
         {:ok, worker_session_id} <- required_worker_session(params, context),
         {:ok, provider_session_id} <- optional_identifier(params, context, :provider_session_id),
         {:ok, design_attempt} <- required_attempt(params, context) do
      {:ok,
       %{
         packet: packet,
         packet_digest: packet_digest,
         task_id: task_id,
         task: task,
         plan_fingerprint: plan_fingerprint,
         workspace_id: workspace_id,
         worker_session_id: worker_session_id,
         provider_session_id: provider_session_id,
         design_attempt: design_attempt
       }}
    end
  end

  def build_common_binding(_params, _context), do: {:error, :invalid_design_checkpoint_input}

  # Validate and normalize the exact design evidence shared by Parse and Open.
  @doc false
  def validate_design_envelope(design, supplied_digest) do
    with {:ok, design} <- validate_design(design),
         {:ok, design_digest} <- validate_design_digest(supplied_digest, design) do
      {:ok, %{"design" => design, "design_digest" => design_digest}}
    end
  end

  @doc false
  def validate_design_artifact_envelope(descriptor_input, supplied_digest) do
    with {:ok, descriptor} <- DesignArtifactDescriptor.normalize(descriptor_input),
         {:ok, design_digest} <- validate_artifact_design_digest(supplied_digest, descriptor) do
      {:ok, %{"design_artifact" => descriptor, "design_digest" => design_digest}}
    end
  end

  # Fail-closed verify + load through the trusted source. Used by Await
  # (before any terminal outcome) and Load (implementation handoff). Capture
  # uses the same consistency checks after archive.
  @doc false
  def verify_design_artifact(context, binding, descriptor_input, design_digest)
      when is_map(context) and is_map(binding) do
    with {:ok, descriptor} <- DesignArtifactDescriptor.normalize(descriptor_input),
         {:ok, fixed_task_id} <- fixed_task_id_from_source(context),
         :ok <- match_task_id(descriptor["task_id"], fixed_task_id, binding),
         :ok <- match_design_attempt(descriptor["design_attempt"], binding),
         :ok <- match_descriptor_digest(descriptor, design_digest),
         {:ok, source} <- design_artifact_source(context),
         {:ok, design} <- call_design_artifact_source(source, descriptor),
         :ok <- match_loaded_design(design, descriptor, design_digest) do
      {:ok, design}
    end
  end

  def verify_design_artifact(_context, _binding, _descriptor, _design_digest),
    do: {:error, :invalid_design_artifact_verify_input}

  @doc false
  def design_artifact_sink(context) when is_map(context) do
    with :ok <- design_artifact_boundary_ready(context) do
      case Map.get(context, :design_artifact_sink) || Map.get(context, "design_artifact_sink") do
        {module, function, fixed_args} = sink
        when is_atom(module) and is_atom(function) and is_list(fixed_args) ->
          {:ok, sink}

        nil ->
          {:error, :invalid_trusted_design_artifact_boundary}

        _ ->
          {:error, :invalid_trusted_design_artifact_boundary}
      end
    end
  end

  def design_artifact_sink(_context), do: {:error, :invalid_trusted_design_artifact_boundary}

  @doc false
  def design_artifact_source(context) when is_map(context) do
    with :ok <- design_artifact_boundary_ready(context) do
      case Map.get(context, :design_artifact_source) || Map.get(context, "design_artifact_source") do
        {module, function, fixed_args} = source
        when is_atom(module) and is_atom(function) and is_list(fixed_args) ->
          {:ok, source}

        nil ->
          {:error, :invalid_trusted_design_artifact_boundary}

        _ ->
          {:error, :invalid_trusted_design_artifact_boundary}
      end
    end
  end

  def design_artifact_source(_context), do: {:error, :invalid_trusted_design_artifact_boundary}

  defp design_artifact_boundary_ready(context) do
    case Map.get(context, :design_artifact_boundary_error) ||
           Map.get(context, "design_artifact_boundary_error") do
      nil -> :ok
      _error -> {:error, :invalid_trusted_design_artifact_boundary}
    end
  end

  @doc false
  def call_design_artifact_sink({module, function, fixed_args}, design_attempt, design)
      when is_atom(module) and is_atom(function) and is_list(fixed_args) and
             is_integer(design_attempt) and is_binary(design) do
    apply(module, function, fixed_args ++ [design_attempt, design])
  rescue
    UndefinedFunctionError -> {:error, :design_artifact_sink_unavailable}
    _ -> {:error, :design_artifact_sink_failed}
  catch
    :exit, _ -> {:error, :design_artifact_sink_unavailable}
    _, _ -> {:error, :design_artifact_sink_failed}
  end

  def call_design_artifact_sink(_sink, _design_attempt, _design),
    do: {:error, :invalid_trusted_design_artifact_boundary}

  @doc false
  def call_design_artifact_source({module, function, fixed_args}, descriptor)
      when is_atom(module) and is_atom(function) and is_list(fixed_args) and is_map(descriptor) do
    apply(module, function, fixed_args ++ [descriptor])
  rescue
    UndefinedFunctionError -> {:error, :design_artifact_source_unavailable}
    _ -> {:error, :design_artifact_source_failed}
  catch
    :exit, _ -> {:error, :design_artifact_source_unavailable}
    _, _ -> {:error, :design_artifact_source_failed}
  end

  def call_design_artifact_source(_source, _descriptor),
    do: {:error, :invalid_trusted_design_artifact_boundary}

  @doc false
  def computed_design_digest(design) when is_binary(design),
    do: "sha256:" <> (:crypto.hash(:sha256, design) |> Base.encode16(case: :lower))

  def computed_design_digest(_design), do: nil

  defp design_evidence_fields(params, context) do
    design_input = value(params, context, :design)
    artifact_input = value(params, context, :design_artifact)
    digest_input = value(params, context, :design_digest)

    cond do
      not is_nil(artifact_input) and not is_nil(design_input) ->
        {:error, :design_checkpoint_mixed_evidence_shape}

      not is_nil(artifact_input) ->
        with {:ok, fields} <- validate_design_artifact_envelope(artifact_input, digest_input) do
          {:ok, fields, :artifact}
        end

      true ->
        with {:ok, fields} <- validate_design_envelope(design_input, digest_input) do
          {:ok, fields, :legacy}
        end
    end
  end

  defp fixed_task_id_from_source(context) do
    with {:ok, {_module, _function, fixed_args}} <- design_artifact_source(context) do
      case fixed_args do
        [_root, task_id] when is_binary(task_id) and task_id != "" ->
          {:ok, task_id}

        _ ->
          {:error, :invalid_trusted_design_artifact_boundary}
      end
    end
  end

  defp match_task_id(descriptor_task_id, fixed_task_id, binding) do
    binding_task_id = binding[:task_id] || binding["task_id"]

    cond do
      descriptor_task_id !== fixed_task_id ->
        {:error, :design_artifact_task_id_mismatch}

      binding_task_id !== fixed_task_id ->
        {:error, :design_artifact_task_id_mismatch}

      true ->
        :ok
    end
  end

  defp match_design_attempt(descriptor_attempt, binding) do
    binding_attempt = binding[:design_attempt] || binding["design_attempt"]

    if descriptor_attempt === binding_attempt,
      do: :ok,
      else: {:error, :design_artifact_attempt_mismatch}
  end

  defp match_descriptor_digest(descriptor, design_digest) when is_binary(design_digest) do
    expected = "sha256:" <> descriptor["sha256"]

    if design_digest === expected and descriptor["byte_size"] > 0,
      do: :ok,
      else: {:error, :design_artifact_digest_mismatch}
  end

  defp match_descriptor_digest(_descriptor, _design_digest),
    do: {:error, :design_artifact_digest_mismatch}

  defp match_loaded_design(design, descriptor, design_digest) when is_binary(design) do
    with {:ok, ^design} <- validate_design(design),
         true <- byte_size(design) == descriptor["byte_size"],
         true <- computed_design_digest(design) == design_digest,
         true <-
           :crypto.hash(:sha256, design) |> Base.encode16(case: :lower) == descriptor["sha256"] do
      :ok
    else
      false -> {:error, :design_artifact_digest_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp match_loaded_design(_design, _descriptor, _design_digest),
    do: {:error, :design_artifact_load_failed}

  defp validate_artifact_design_digest(supplied, descriptor) when is_map(descriptor) do
    expected = "sha256:" <> descriptor["sha256"]

    if is_binary(supplied) and supplied === expected,
      do: {:ok, expected},
      else: {:error, :design_digest_mismatch}
  end

  defp validate_artifact_design_digest(_supplied, _descriptor),
    do: {:error, :design_digest_mismatch}

  # Server-owned digest admission: the caller supplies only `design`, and
  # Arbor computes the sha256 digest itself from the exact admitted bytes.
  # There is no supplied digest to validate, so no mismatch is possible.
  defp validate_design_only_envelope(design) do
    with {:ok, design} <- validate_design(design) do
      {:ok, %{"design" => design, "design_digest" => computed_design_digest(design)}}
    end
  end

  # Progress prose and unrelated top-level JSON values are ignored. Identical
  # duplicate envelopes are tolerated because some ACP clients concatenate the
  # terminal payload twice. Raw response text remains the caller's audit
  # responsibility and is never returned from this parser. A candidate object
  # is admitted with exactly `design` alone (Arbor computes the digest from
  # the exact admitted bytes) or with the legacy `design`+`design_digest`
  # pair (the supplied digest must match exactly). Any other field shape,
  # including a lone `design_digest`, is rejected.
  @doc false
  def parse_design_envelope(text)
      when is_binary(text) and byte_size(text) <= @max_terminal_response_bytes do
    with {:ok, objects} <- scan_top_level_json_objects(text),
         {:ok, envelopes} <- validate_candidate_objects(objects) do
      case Enum.uniq(envelopes) do
        [envelope] -> {:ok, envelope}
        [] -> {:error, :design_envelope_not_found}
        _conflicting -> {:error, :conflicting_design_envelopes}
      end
    end
  end

  def parse_design_envelope(text)
      when is_binary(text) and byte_size(text) > @max_terminal_response_bytes,
      do: {:error, :design_envelope_response_too_large}

  def parse_design_envelope(_text), do: {:error, :design_envelope_text_required}

  @doc false
  def request_id(evidence) when is_map(evidence) do
    with {:ok, canonical} <- canonical_evidence(evidence) do
      digest = :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
      {:ok, @request_prefix <> digest}
    end
  end

  @doc false
  def request_id(_evidence), do: {:error, :invalid_design_checkpoint_evidence}

  @doc false
  def canonical_evidence(evidence) when is_map(evidence) do
    cond do
      Map.has_key?(evidence, "design_artifact") and Map.has_key?(evidence, "design") ->
        {:error, :design_checkpoint_mixed_evidence_shape}

      Map.has_key?(evidence, "design_artifact") ->
        encode_canonical_evidence(evidence, @artifact_evidence_keys)

      true ->
        encode_canonical_evidence(evidence, @legacy_evidence_keys)
    end
  end

  @doc false
  def canonical_evidence(_evidence), do: {:error, :design_checkpoint_evidence_not_map}

  defp encode_canonical_evidence(evidence, keys) do
    if Enum.all?(keys, &Map.has_key?(evidence, &1)) do
      ordered =
        keys
        |> Enum.map(&{&1, Map.fetch!(evidence, &1)})
        |> Jason.OrderedObject.new()

      case Jason.encode(ordered) do
        {:ok, bytes} -> {:ok, bytes}
        {:error, _reason} -> {:error, :design_checkpoint_evidence_not_json}
      end
    else
      {:error, :design_checkpoint_evidence_incomplete}
    end
  end

  @doc false
  def normalize_response(response, metadata, request_id, evidence)
      when is_binary(request_id) and is_map(evidence) do
    with :ok <- validate_authority_evidence(metadata, request_id, evidence) do
      case Arbor.Contracts.Comms.ApprovalAnswer.normalize(response, metadata) do
        {:ok, :approve} -> {:ok, "approve", ""}
        {:ok, :rework, note} -> {:ok, "rework", note}
        {:ok, :deny, note} -> {:ok, "deny", note}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc false
  def normalize_response(_response, _metadata, _request_id, _evidence),
    do: {:error, :invalid_design_checkpoint_response}

  @doc false
  def timeout(context, params) do
    value = value(params, context, :timeout) || value(context, %{}, :approval_timeout_ms)

    case value || @default_timeout do
      timeout when is_integer(timeout) and timeout > 0 and timeout <= @max_timeout ->
        {:ok, timeout}

      _ ->
        {:error, :invalid_design_checkpoint_timeout}
    end
  end

  @doc """
  Construct the absolute deadline persisted with a durable design request.

  Open owns deadline arming: the requested durable deadline is the earlier of
  the Engine owner's absolute run deadline and `now + timeout`. An already
  elapsed owner deadline is rejected before Comms is consulted.
  """
  def durable_request_deadline(context, params, now_ms \\ System.system_time(:millisecond))

  def durable_request_deadline(context, params, now_ms)
      when is_map(context) and is_map(params) and is_integer(now_ms) do
    with {:ok, static_timeout} <- timeout(context, params),
         {:ok, owner_deadline_unix_ms} <- run_deadline_unix_ms(params, context),
         :ok <- future_deadline(owner_deadline_unix_ms, now_ms) do
      {:ok, min(owner_deadline_unix_ms, now_ms + static_timeout)}
    end
  end

  def durable_request_deadline(_context, _params, _now_ms),
    do: {:error, :invalid_design_checkpoint_input}

  @doc false
  def comms_boundary(context) when is_map(context) do
    case Map.get(context, :comms_boundary) || Map.get(context, "comms_boundary") do
      nil -> {:ok, Arbor.Comms}
      module when is_atom(module) -> {:ok, module}
      _ -> {:error, :invalid_design_checkpoint_comms_boundary}
    end
  end

  @doc false
  def comms_boundary(_context), do: {:error, :invalid_design_checkpoint_comms_boundary}

  @doc false
  def call(module, function, args) when is_atom(module) and is_atom(function) and is_list(args) do
    apply(module, function, args)
  rescue
    UndefinedFunctionError -> {:error, {:design_checkpoint_comms_unavailable, function}}
    _ -> {:error, {:design_checkpoint_comms_failed, function}}
  catch
    :exit, _ -> {:error, {:design_checkpoint_comms_unavailable, function}}
  end

  @doc false
  def call(_module, _function, _args), do: {:error, :invalid_design_checkpoint_comms_boundary}

  @doc false
  def durable_ready?(module) do
    case call(module, :durable_ready?, []) do
      true -> :ok
      false -> {:error, :durable_interaction_unavailable}
      {:error, _reason} -> {:error, :durable_interaction_unavailable}
      _ -> {:error, :durable_interaction_unavailable}
    end
  end

  @doc false
  def validate_operator(value) when is_binary(value), do: validate_identifier(value, :operator_id)
  def validate_operator(_value), do: {:error, :design_checkpoint_operator_invalid}

  @doc false
  def string_value(value) when is_binary(value), do: value

  def string_value(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  def string_value(_value), do: nil

  @doc false
  def validate_persisted_deadline(deadline) when is_integer(deadline) and deadline > 0,
    do: {:ok, deadline}

  def validate_persisted_deadline(_deadline),
    do: {:error, :invalid_design_checkpoint_persisted_deadline}

  @doc false
  def validate_operation_id(value) do
    case string_value(value) do
      value when is_binary(value) -> validate_identifier(value, :operation_id)
      _ -> {:error, :design_checkpoint_operation_id_required}
    end
  end

  defp normalize_work_packet(value) do
    case WorkPacket.normalize(value) do
      {:ok, packet} -> {:ok, packet}
      {:error, reason} -> {:error, {:invalid_work_packet, reason}}
    end
  end

  defp require_design_policy(%{"checkpoint_policy" => "design_required"}), do: :ok
  defp require_design_policy(_packet), do: {:error, :design_checkpoint_policy_required}

  defp run_deadline_unix_ms(params, context) do
    case deadline_input(context) do
      :missing -> params |> deadline_input() |> validate_run_deadline()
      context_input -> validate_run_deadline(context_input)
    end
  end

  defp deadline_input(source) do
    case {
      Map.fetch(source, :run_deadline_unix_ms),
      Map.fetch(source, "run_deadline_unix_ms")
    } do
      {:error, :error} -> :missing
      {{:ok, deadline}, :error} -> {:ok, deadline}
      {:error, {:ok, deadline}} -> {:ok, deadline}
      {{:ok, deadline}, {:ok, deadline}} -> {:ok, deadline}
      {{:ok, _atom_deadline}, {:ok, _string_deadline}} -> :conflict
    end
  end

  defp validate_run_deadline(:missing), do: {:error, :design_checkpoint_run_deadline_required}
  defp validate_run_deadline(:conflict), do: {:error, :invalid_design_checkpoint_run_deadline}

  defp validate_run_deadline({:ok, deadline}) when is_integer(deadline) and deadline > 0,
    do: {:ok, deadline}

  defp validate_run_deadline({:ok, _deadline}),
    do: {:error, :invalid_design_checkpoint_run_deadline}

  defp future_deadline(deadline, now_ms) when deadline > now_ms, do: :ok
  defp future_deadline(_deadline, _now_ms), do: {:error, :design_checkpoint_run_deadline_elapsed}

  defp validate_packet_digest(packet, supplied) do
    with {:ok, expected} <- WorkPacket.digest(packet),
         true <- is_binary(supplied) and supplied === expected do
      {:ok, expected}
    else
      false -> {:error, :work_packet_digest_mismatch}
      {:error, reason} -> {:error, {:work_packet_digest_unavailable, reason}}
    end
  end

  defp required(params, context, key, context_key) do
    case value(params, context, key) || value(context, %{}, context_key) do
      nil -> {:error, {:design_checkpoint_field_required, Atom.to_string(key)}}
      value -> {:ok, value}
    end
  end

  defp packet_digest_input(params, context) do
    case value(params, context, :packet_digest) || value(params, context, :work_packet_digest) ||
           value(context, %{}, :coding_plan_work_packet_digest) do
      nil -> {:error, {:design_checkpoint_field_required, "packet_digest"}}
      digest -> {:ok, digest}
    end
  end

  defp required_task(params, context) do
    case value(params, context, :task) do
      task
      when is_binary(task) and byte_size(task) > 0 and byte_size(task) <= @max_task_bytes ->
        cond do
          not String.valid?(task) ->
            {:error, :design_checkpoint_task_invalid_utf8}

          String.trim(task) == "" ->
            {:error, :design_checkpoint_task_blank}

          has_disallowed_design_control?(task) ->
            {:error, :design_checkpoint_task_control_character}

          true ->
            {:ok, task}
        end

      task when is_binary(task) and byte_size(task) > @max_task_bytes ->
        {:error, :design_checkpoint_task_too_large}

      _ ->
        {:error, :design_checkpoint_task_required}
    end
  end

  defp plan_fingerprint_input(params, context) do
    candidates =
      [
        Map.get(params, :plan_fingerprint),
        Map.get(params, "plan_fingerprint"),
        Map.get(params, :coding_plan_fingerprint),
        Map.get(params, "coding_plan_fingerprint"),
        Map.get(context, :plan_fingerprint),
        Map.get(context, "plan_fingerprint"),
        Map.get(context, :coding_plan_fingerprint),
        Map.get(context, "coding_plan_fingerprint")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case candidates do
      [] -> {:error, :design_checkpoint_plan_fingerprint_required}
      [fingerprint] -> validate_plan_fingerprint(fingerprint)
      _ -> {:error, :design_checkpoint_plan_fingerprint_mismatch}
    end
  end

  defp validate_plan_fingerprint(value) when is_binary(value) do
    cond do
      byte_size(value) != 64 ->
        {:error, :design_checkpoint_plan_fingerprint_invalid}

      not String.valid?(value) ->
        {:error, :design_checkpoint_plan_fingerprint_invalid_utf8}

      has_ascii_control?(value) ->
        {:error, :design_checkpoint_plan_fingerprint_control_character}

      not Regex.match?(~r/\A[0-9a-f]{64}\z/, value) ->
        {:error, :design_checkpoint_plan_fingerprint_invalid}

      true ->
        {:ok, value}
    end
  end

  defp validate_plan_fingerprint(_value),
    do: {:error, :design_checkpoint_plan_fingerprint_invalid}

  defp required_identifier(params, context, key) do
    case string_value(value(params, context, key)) do
      value when is_binary(value) -> validate_identifier(value, key)
      _ -> {:error, {:design_checkpoint_identifier_required, Atom.to_string(key)}}
    end
  end

  defp required_worker_session(params, context) do
    value =
      value(params, context, :worker_session_id) ||
        value(params, context, :worker_acp_handle) ||
        value(params, context, :worker_session)

    case string_value(value) do
      value when is_binary(value) -> validate_identifier(value, :worker_session_id)
      _ -> {:error, :design_checkpoint_worker_session_required}
    end
  end

  defp optional_identifier(params, context, key) do
    case value(params, context, key) || value(params, context, :worker_provider_session_id) do
      nil ->
        {:ok, nil}

      value ->
        case string_value(value) do
          value when is_binary(value) -> validate_identifier(value, key)
          _ -> {:error, {:design_checkpoint_identifier_invalid, Atom.to_string(key)}}
        end
    end
  end

  defp validate_identifier(value, key) when is_binary(value) do
    if byte_size(value) > 0 and byte_size(value) <= @max_identifier_bytes and
         String.valid?(value) and value == String.trim(value) and
         not String.contains?(value, <<0>>) and not has_ascii_control?(value) do
      {:ok, value}
    else
      {:error, {:design_checkpoint_identifier_invalid, Atom.to_string(key)}}
    end
  end

  defp validate_identifier(_value, key),
    do: {:error, {:design_checkpoint_identifier_invalid, Atom.to_string(key)}}

  defp required_attempt(params, context) do
    case value(params, context, :design_attempt) do
      value when is_integer(value) and value > 0 and value <= 1_000_000 -> {:ok, value}
      _ -> {:error, :design_checkpoint_attempt_invalid}
    end
  end

  defp validate_design(value)
       when is_binary(value) and byte_size(value) > 0 and
              byte_size(value) <= @max_design_bytes do
    cond do
      not String.valid?(value) ->
        {:error, :design_checkpoint_design_invalid_utf8}

      String.trim(value) == "" ->
        {:error, :design_checkpoint_design_blank}

      String.contains?(value, <<0>>) or has_disallowed_design_control?(value) ->
        {:error, :design_checkpoint_design_control_character}

      true ->
        {:ok, value}
    end
  end

  defp validate_design(value)
       when is_binary(value) and byte_size(value) > @max_design_bytes,
       do: {:error, :design_checkpoint_design_too_large}

  defp validate_design(_value), do: {:error, :design_checkpoint_design_required}

  defp validate_design_digest(supplied, design) do
    expected = computed_design_digest(design)

    if is_binary(supplied) and supplied === expected,
      do: {:ok, expected},
      else: {:error, :design_digest_mismatch}
  end

  # Short operator prose only. Exact work packet, task, plan fingerprint, and
  # design remain in metadata and bind the deterministic request id.
  defp description(task_id, design_attempt, packet_digest, design_digest)
       when is_binary(task_id) and is_integer(design_attempt) and is_binary(packet_digest) and
              is_binary(design_digest) do
    description =
      "Design checkpoint for task #{task_id} (attempt #{design_attempt}). " <>
        "Review metadata for the exact work packet (#{packet_digest}), task, " <>
        "plan fingerprint, and design (#{design_digest})."

    if String.valid?(description) and byte_size(description) <= @max_operator_prose_bytes do
      {:ok, description}
    else
      {:error, :design_checkpoint_description_too_large}
    end
  end

  defp description(_task_id, _design_attempt, _packet_digest, _design_digest),
    do: {:error, :design_checkpoint_description_unavailable}

  # Metadata carries exact evidence without an action-local aggregate size
  # ceiling. `Open` admits the payload through the public Comms validator.
  defp metadata(base_evidence, packet) do
    metadata = Map.put(base_evidence, "work_packet", packet)

    case Jason.encode(metadata) do
      {:ok, _encoded} -> {:ok, metadata}
      {:error, _reason} -> {:error, :design_checkpoint_metadata_not_json}
    end
  end

  defp validate_authority_evidence(metadata, request_id, evidence) when is_map(metadata) do
    with :ok <- optional_equal(metadata, :request_id, request_id),
         :ok <- optional_equal(metadata, :task_id, evidence["task_id"]),
         :ok <- optional_equal(metadata, :task, evidence["task"]),
         :ok <- optional_equal(metadata, :plan_fingerprint, evidence["plan_fingerprint"]),
         :ok <- optional_equal(metadata, :workspace_id, evidence["workspace_id"]),
         :ok <- optional_equal(metadata, :worker_session_id, evidence["worker_session_id"]),
         :ok <- optional_equal(metadata, :provider_session_id, evidence["provider_session_id"]),
         :ok <- optional_equal(metadata, :design_attempt, evidence["design_attempt"]),
         :ok <- optional_equal(metadata, :packet_digest, evidence["packet_digest"]),
         :ok <- optional_equal(metadata, :design_digest, evidence["design_digest"]),
         :ok <- optional_equal(metadata, :design, evidence["design"]),
         :ok <- optional_equal(metadata, :design_artifact, evidence["design_artifact"]),
         :ok <- optional_nested_evidence(metadata, request_id, evidence) do
      :ok
    end
  end

  defp validate_authority_evidence(_metadata, _request_id, _evidence),
    do: {:error, :malformed_design_checkpoint_authority_evidence}

  defp optional_equal(metadata, key, expected) do
    case fetch_optional(metadata, key) do
      :missing -> :ok
      {:ok, ^expected} -> :ok
      {:ok, _other} -> {:error, {:design_checkpoint_authority_mismatch, Atom.to_string(key)}}
    end
  end

  defp optional_nested_evidence(metadata, request_id, evidence) do
    nested =
      case fetch_optional(metadata, :evidence) do
        :missing -> fetch_optional(metadata, :authority_evidence)
        found -> found
      end

    case nested do
      :missing ->
        :ok

      {:ok, value} when is_map(value) ->
        expected = Map.put(evidence, "request_id", request_id)
        if value == expected, do: :ok, else: {:error, :design_checkpoint_authority_mismatch}

      {:ok, _value} ->
        {:error, :malformed_design_checkpoint_authority_evidence}
    end
  end

  defp fetch_optional(map, key) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.fetch!(map, key)}
      Map.has_key?(map, Atom.to_string(key)) -> {:ok, Map.fetch!(map, Atom.to_string(key))}
      true -> :missing
    end
  end

  defp context_agent_id(params, context) do
    direct = value(params, context, :agent_id) || value(params, context, :principal_id)

    authority =
      case Map.get(context, :auth_context) || Map.get(context, "auth_context") do
        auth when is_map(auth) ->
          Map.get(auth, :agent_id) || Map.get(auth, "agent_id") ||
            Map.get(auth, :principal_id) || Map.get(auth, "principal_id")

        _ ->
          nil
      end

    case string_value(direct || authority) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp value(primary, secondary, key) do
    Map.get(primary, key) || Map.get(primary, Atom.to_string(key)) || Map.get(secondary, key) ||
      Map.get(secondary, Atom.to_string(key))
  end

  defp scan_top_level_json_objects(text),
    do: scan_top_level_json_objects(text, 0, 0, [])

  defp scan_top_level_json_objects(text, offset, attempts, objects) do
    case next_composite_start(text, offset) do
      :none ->
        {:ok, Enum.reverse(objects)}

      _start when attempts >= @max_json_scan_attempts ->
        {:error, :design_envelope_scan_limit_exceeded}

      start ->
        case balanced_composite_end(text, start) do
          {:ok, finish} ->
            candidate = binary_part(text, start, finish - start + 1)

            case Jason.decode(candidate, objects: :ordered_objects) do
              {:ok, %Jason.OrderedObject{} = object} ->
                scan_top_level_json_objects(text, finish + 1, attempts + 1, [object | objects])

              {:ok, _other_json} ->
                scan_top_level_json_objects(text, finish + 1, attempts + 1, objects)

              {:error, _reason} ->
                scan_top_level_json_objects(text, finish + 1, attempts + 1, objects)
            end

          :unbalanced ->
            {:error, :design_envelope_unbalanced_json}
        end
    end
  end

  defp next_composite_start(text, offset) when offset >= byte_size(text), do: :none

  defp next_composite_start(text, offset) do
    remaining = byte_size(text) - offset
    brace = match_offset(text, "{", offset, remaining)
    bracket = match_offset(text, "[", offset, remaining)

    case {brace, bracket} do
      {:none, :none} -> :none
      {:none, start} -> start
      {start, :none} -> start
      {brace_start, bracket_start} -> min(brace_start, bracket_start)
    end
  end

  defp match_offset(text, pattern, offset, length) do
    case :binary.match(text, pattern, scope: {offset, length}) do
      {start, _length} -> start
      :nomatch -> :none
    end
  end

  defp balanced_composite_end(text, start) do
    expected_closer =
      case :binary.at(text, start) do
        ?{ -> ?}
        ?[ -> ?]
      end

    scan_composite(text, start + 1, [expected_closer], false, false)
  end

  defp scan_composite(text, offset, _closers, _in_string?, _escaped?)
       when offset >= byte_size(text),
       do: :unbalanced

  defp scan_composite(text, offset, closers, true, true),
    do: scan_composite(text, offset + 1, closers, true, false)

  defp scan_composite(text, offset, closers, true, false) do
    case :binary.at(text, offset) do
      ?\\ -> scan_composite(text, offset + 1, closers, true, true)
      ?" -> scan_composite(text, offset + 1, closers, false, false)
      _byte -> scan_composite(text, offset + 1, closers, true, false)
    end
  end

  defp scan_composite(text, offset, closers, false, false) do
    case {:binary.at(text, offset), closers} do
      {?", _} ->
        scan_composite(text, offset + 1, closers, true, false)

      {?{, _} ->
        scan_composite(text, offset + 1, [?} | closers], false, false)

      {?[, _} ->
        scan_composite(text, offset + 1, [?] | closers], false, false)

      {closer, [closer]} ->
        {:ok, offset}

      {closer, [closer | remaining]} ->
        scan_composite(text, offset + 1, remaining, false, false)

      {closer, _} when closer in [?}, ?]] ->
        :unbalanced

      {_byte, _} ->
        scan_composite(text, offset + 1, closers, false, false)
    end
  end

  defp validate_candidate_objects(objects) do
    Enum.reduce_while(objects, {:ok, []}, fn object, {:ok, envelopes} ->
      case validate_candidate_object(object) do
        :unrelated -> {:cont, {:ok, envelopes}}
        {:ok, envelope} -> {:cont, {:ok, [envelope | envelopes]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_candidate_object(%Jason.OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if Enum.any?(keys, &(&1 in @design_envelope_keys)) do
      cond do
        keys == ~w(design) ->
          envelope = Map.new(pairs)
          validate_design_only_envelope(envelope["design"])

        length(keys) == length(@design_envelope_keys) and
            MapSet.new(keys) == MapSet.new(@design_envelope_keys) ->
          envelope = Map.new(pairs)
          validate_design_envelope(envelope["design"], envelope["design_digest"])

        true ->
          {:error, :invalid_design_envelope_fields}
      end
    else
      :unrelated
    end
  end

  defp has_ascii_control?(value), do: has_ascii_control?(value, false)
  defp has_ascii_control?(<<>>, seen), do: seen

  defp has_ascii_control?(<<byte, _rest::binary>>, _seen) when byte <= 0x1F or byte == 0x7F,
    do: true

  defp has_ascii_control?(<<_byte, rest::binary>>, seen), do: has_ascii_control?(rest, seen)

  defp has_disallowed_design_control?(value), do: has_disallowed_design_control?(value, false)
  defp has_disallowed_design_control?(<<>>, seen), do: seen

  defp has_disallowed_design_control?(<<byte, _rest::binary>>, _seen)
       when byte in [0x00, 0x0B, 0x0C, 0x7F],
       do: true

  defp has_disallowed_design_control?(<<_byte, rest::binary>>, seen),
    do: has_disallowed_design_control?(rest, seen)
end

defmodule Arbor.Actions.Coding.DesignCheckpoint.Parse do
  @moduledoc """
  Parse the strict CodingPlan v2 terminal design envelope from ACP response text.

  This pipeline-internal action is bounded, pure, and read-only. The caller
  retains the raw ACP transcript separately for audit.
  """

  use Jido.Action,
    name: "coding_design_envelope_parse",
    description: "Parse and verify the terminal CodingPlan v2 design envelope",
    category: "coding",
    tags: ["coding", "design_checkpoint", "parser", "pipeline_internal"],
    schema: [
      text: [type: :string, required: true, doc: "Raw bounded ACP response text"]
    ]

  alias Arbor.Actions.Coding.DesignCheckpoint

  def taint_roles, do: %{text: :data}
  def effect_class, do: :read
  def execution_idempotency, do: :read_only

  @impl true
  def run(params, _context) when is_map(params) do
    text = Map.get(params, :text) || Map.get(params, "text")
    DesignCheckpoint.parse_design_envelope(text)
  end

  def run(_params, _context), do: {:error, :design_envelope_text_required}
end

defmodule Arbor.Actions.Coding.DesignCheckpoint.Capture do
  @moduledoc """
  Persist the exact admitted design as an immutable task-owned artifact.

  Uses only the executor-installed trusted sink. Action params never supply
  store module/function/root authority.
  """

  use Jido.Action,
    name: "coding_design_artifact_capture",
    description: "Archive the exact coding design as a task-owned artifact",
    category: "coding",
    tags: ["coding", "design_checkpoint", "artifact", "pipeline_internal"],
    schema: [
      design: [type: :string, required: true, doc: "Exact admitted design text"],
      design_digest: [type: :string, required: true, doc: "Exact sha256: design digest"],
      task_id: [type: :string, required: true, doc: "Coding task identity"],
      design_attempt: [type: :integer, required: true, doc: "One-based design attempt"]
    ]

  alias Arbor.Actions.Coding.DesignCheckpoint
  alias Arbor.Contracts.Coding.DesignArtifactDescriptor

  def taint_roles do
    %{
      design: :data,
      design_digest: :control,
      task_id: :control,
      design_attempt: :control
    }
  end

  def effect_class, do: :local_write
  def execution_idempotency, do: :idempotent_with_key

  @impl true
  def run(params, context) when is_map(params) and is_map(context) do
    with {:ok, design, design_digest} <- admitted_design(params, context),
         {:ok, task_id} <- required_task_id(params, context),
         {:ok, design_attempt} <- required_attempt(params, context),
         {:ok, sink} <- DesignCheckpoint.design_artifact_sink(context),
         {:ok, fixed_task_id} <- fixed_task_id(sink),
         :ok <- match_task_id(task_id, fixed_task_id),
         {:ok, descriptor} <-
           DesignCheckpoint.call_design_artifact_sink(sink, design_attempt, design),
         {:ok, descriptor} <- DesignArtifactDescriptor.normalize(descriptor),
         :ok <- match_descriptor(descriptor, fixed_task_id, design_attempt, design_digest),
         :ok <- maybe_reverify(context, descriptor, design_digest, fixed_task_id, design_attempt) do
      {:ok,
       %{
         "design_artifact" => descriptor,
         "design_digest" => design_digest,
         "byte_size" => descriptor["byte_size"]
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def run(_params, _context), do: {:error, :invalid_design_artifact_capture_input}

  defp admitted_design(params, context) do
    design = Map.get(params, :design) || Map.get(params, "design") || Map.get(context, :design)
    digest = Map.get(params, :design_digest) || Map.get(params, "design_digest")

    case DesignCheckpoint.validate_design_envelope(design, digest) do
      {:ok, %{"design" => design, "design_digest" => design_digest}} ->
        {:ok, design, design_digest}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp required_task_id(params, context) do
    case Map.get(params, :task_id) || Map.get(params, "task_id") || Map.get(context, :task_id) ||
           Map.get(context, "task_id") || Map.get(context, "session.task_id") do
      task_id when is_binary(task_id) and task_id != "" -> {:ok, task_id}
      _ -> {:error, {:design_checkpoint_identifier_required, "task_id"}}
    end
  end

  defp required_attempt(params, context) do
    case Map.get(params, :design_attempt) || Map.get(params, "design_attempt") ||
           Map.get(context, :design_attempt) || Map.get(context, "design_attempt") do
      value when is_integer(value) and value > 0 and value <= 1_000_000 -> {:ok, value}
      _ -> {:error, :design_checkpoint_attempt_invalid}
    end
  end

  defp fixed_task_id({_module, _function, [_root, task_id]})
       when is_binary(task_id) and task_id != "",
       do: {:ok, task_id}

  defp fixed_task_id(_sink), do: {:error, :invalid_trusted_design_artifact_boundary}

  defp match_task_id(task_id, task_id), do: :ok
  defp match_task_id(_task_id, _fixed), do: {:error, :design_artifact_task_id_mismatch}

  defp match_descriptor(descriptor, task_id, design_attempt, design_digest) do
    expected_digest = "sha256:" <> descriptor["sha256"]

    cond do
      descriptor["task_id"] !== task_id ->
        {:error, :design_artifact_task_id_mismatch}

      descriptor["design_attempt"] !== design_attempt ->
        {:error, :design_artifact_attempt_mismatch}

      design_digest !== expected_digest ->
        {:error, :design_artifact_digest_mismatch}

      true ->
        :ok
    end
  end

  defp maybe_reverify(context, descriptor, design_digest, task_id, design_attempt) do
    case DesignCheckpoint.design_artifact_source(context) do
      {:ok, _source} ->
        binding = %{task_id: task_id, design_attempt: design_attempt}

        case DesignCheckpoint.verify_design_artifact(
               context,
               binding,
               descriptor,
               design_digest
             ) do
          {:ok, _design} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, :invalid_trusted_design_artifact_boundary} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end

defmodule Arbor.Actions.Coding.DesignCheckpoint.Load do
  @moduledoc """
  Load and re-verify the exact design artifact for implementation handoff.

  Fail-closed: missing, tampered, path-escaped, wrong-task, wrong-attempt, or
  digest-mismatched artifacts cannot be loaded.
  """

  use Jido.Action,
    name: "coding_design_artifact_load",
    description: "Load the verified coding design artifact for implementation",
    category: "coding",
    tags: ["coding", "design_checkpoint", "artifact", "pipeline_internal"],
    schema: [
      design_artifact: [
        type: :map,
        required: true,
        doc: "Closed design artifact descriptor"
      ],
      design_digest: [type: :string, required: true, doc: "Exact sha256: design digest"],
      task_id: [type: :string, required: true, doc: "Coding task identity"],
      design_attempt: [type: :integer, required: true, doc: "One-based design attempt"]
    ]

  alias Arbor.Actions.Coding.DesignCheckpoint

  def taint_roles do
    %{
      design_artifact: :control,
      design_digest: :control,
      task_id: :control,
      design_attempt: :control
    }
  end

  def effect_class, do: :read
  def execution_idempotency, do: :read_only

  @impl true
  def run(params, context) when is_map(params) and is_map(context) do
    with {:ok, descriptor} <- descriptor_input(params, context),
         {:ok, design_digest} <- design_digest_input(params, context),
         {:ok, task_id} <- required_task_id(params, context),
         {:ok, design_attempt} <- required_attempt(params, context),
         binding = %{task_id: task_id, design_attempt: design_attempt},
         {:ok, design} <-
           DesignCheckpoint.verify_design_artifact(context, binding, descriptor, design_digest) do
      {:ok,
       %{
         "design" => design,
         "design_digest" => design_digest,
         "design_artifact" => descriptor
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def run(_params, _context), do: {:error, :invalid_design_artifact_load_input}

  defp descriptor_input(params, context) do
    case Map.get(params, :design_artifact) || Map.get(params, "design_artifact") ||
           Map.get(context, :design_artifact) || Map.get(context, "design_artifact") do
      descriptor when is_map(descriptor) -> {:ok, descriptor}
      _ -> {:error, :design_artifact_descriptor_required}
    end
  end

  defp design_digest_input(params, context) do
    case Map.get(params, :design_digest) || Map.get(params, "design_digest") ||
           Map.get(context, :design_digest) || Map.get(context, "design_digest") do
      digest when is_binary(digest) -> {:ok, digest}
      _ -> {:error, :design_digest_mismatch}
    end
  end

  defp required_task_id(params, context) do
    case Map.get(params, :task_id) || Map.get(params, "task_id") || Map.get(context, :task_id) ||
           Map.get(context, "task_id") || Map.get(context, "session.task_id") do
      task_id when is_binary(task_id) and task_id != "" -> {:ok, task_id}
      _ -> {:error, {:design_checkpoint_identifier_required, "task_id"}}
    end
  end

  defp required_attempt(params, context) do
    case Map.get(params, :design_attempt) || Map.get(params, "design_attempt") ||
           Map.get(context, :design_attempt) || Map.get(context, "design_attempt") do
      value when is_integer(value) and value > 0 and value <= 1_000_000 -> {:ok, value}
      _ -> {:error, :design_checkpoint_attempt_invalid}
    end
  end
end

defmodule Arbor.Actions.Coding.DesignCheckpoint.Open do
  @moduledoc """
  Open a durable, operator-facing design approval for a CodingPlan v2 task.

  This pipeline-internal action is the one external-peer edge in the design
  checkpoint. It uses `:external_peer` classification so the human approval
  request does not recursively ask for provider approval.
  """

  use Jido.Action,
    name: "coding_design_checkpoint_open",
    description: "Open a durable operator approval for the exact coding design",
    category: "coding",
    tags: ["coding", "design_checkpoint", "approval", "pipeline_internal"],
    schema: [
      work_packet: [type: :map, required: true, doc: "Canonical CodingPlan v2 work packet"],
      packet_digest: [type: :string, required: false, doc: "Exact sha256: work-packet digest"],
      work_packet_digest: [type: :string, required: false, doc: "Alias for packet_digest"],
      task_id: [type: :string, required: true, doc: "Coding task identity"],
      task: [type: :string, required: true, doc: "Exact nonempty reviewed coding task text"],
      plan_fingerprint: [type: :string, required: true, doc: "Exact compiled plan fingerprint"],
      coding_plan_fingerprint: [
        type: :string,
        required: false,
        doc: "Canonical graph-context alias for plan_fingerprint"
      ],
      workspace_id: [type: :string, required: true, doc: "Leased workspace identity"],
      worker_session_id: [type: :string, required: true, doc: "Managed ACP worker handle"],
      provider_session_id: [type: :string, required: false, doc: "Provider session id alias"],
      worker_provider_session_id: [type: :string, required: false, doc: "Provider session id"],
      design_attempt: [type: :integer, required: true, doc: "One-based design attempt"],
      design: [
        type: :string,
        required: false,
        doc: "Legacy inline design text when design_artifact is absent"
      ],
      design_artifact: [
        type: :map,
        required: false,
        doc: "Closed design artifact descriptor for the artifact-backed path"
      ],
      design_digest: [type: :string, required: true, doc: "Exact sha256: design digest"],
      agent_id: [type: :string, required: false, doc: "Owning agent identity"],
      run_deadline_unix_ms: [
        type: :integer,
        required: true,
        doc: "Executor-owned absolute run deadline in Unix milliseconds"
      ],
      timeout: [
        type: :integer,
        required: true,
        doc: "Static design-checkpoint timeout in milliseconds"
      ]
    ]

  alias Arbor.Actions.Coding.DesignCheckpoint
  alias Arbor.Contracts.Comms.Interaction

  def taint_roles do
    %{
      work_packet: :data,
      packet_digest: :control,
      work_packet_digest: :control,
      task_id: :control,
      task: :data,
      plan_fingerprint: :control,
      coding_plan_fingerprint: :control,
      workspace_id: :control,
      worker_session_id: :control,
      provider_session_id: :control,
      worker_provider_session_id: :control,
      design_attempt: :control,
      design: :data,
      design_artifact: :control,
      design_digest: :control,
      agent_id: :control,
      run_deadline_unix_ms: :control,
      timeout: :control
    }
  end

  def effect_class, do: :network_egress
  def egress_tier(_params, _context), do: :external_peer

  @impl true
  def run(params, context) when is_map(params) and is_map(context) do
    with {:ok, binding} <- DesignCheckpoint.build_binding(params, context),
         {:ok, agent_id} <- required_agent_id(binding),
         {:ok, requested_deadline_unix_ms} <-
           DesignCheckpoint.durable_request_deadline(context, params),
         {:ok, comms} <- DesignCheckpoint.comms_boundary(context),
         :ok <- DesignCheckpoint.durable_ready?(comms),
         {:ok, operator_id} <- operator_id(comms, agent_id),
         {:ok, interaction} <- interaction(binding, agent_id, operator_id),
         # Pure public contract check: rejects oversized description/metadata
         # before the injected Comms boundary or Authority is consulted.
         :ok <- Arbor.Comms.validate_durable_interaction_payload(interaction),
         {:ok, receipt} <-
           DesignCheckpoint.call(comms, :request_durable_interaction, [
             interaction,
             [owner_deadline_unix_ms: requested_deadline_unix_ms]
           ]),
         {:ok, operation_id, owner_deadline_unix_ms} <-
           durable_receipt(receipt, binding.request_id, requested_deadline_unix_ms) do
      {:ok,
       %{
         "checkpoint_outcome" => "pending",
         "request_id" => binding.request_id,
         "operation_id" => operation_id,
         "owner_deadline_unix_ms" => owner_deadline_unix_ms,
         "evidence" => binding.evidence
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def run(_params, _context), do: {:error, :invalid_design_checkpoint_input}

  defp required_agent_id(%{agent_id: agent_id}) when is_binary(agent_id) and agent_id != "",
    do: {:ok, agent_id}

  defp required_agent_id(_binding), do: {:error, :design_checkpoint_agent_id_required}

  defp operator_id(comms, agent_id) do
    case DesignCheckpoint.call(comms, :operator_for_agent, [agent_id]) do
      operator when is_binary(operator) ->
        DesignCheckpoint.validate_operator(operator)

      {:error, _reason} ->
        {:error, :design_checkpoint_operator_unavailable}

      _ ->
        {:error, :design_checkpoint_operator_invalid}
    end
  end

  defp interaction(binding, agent_id, operator_id) do
    attrs = %{
      request_id: binding.request_id,
      kind: :approval,
      agent_id: agent_id,
      user_id: operator_id,
      description: binding.description,
      metadata: binding.metadata,
      resource_uri: "arbor://action/coding/design_checkpoint"
    }

    case Interaction.new(attrs) do
      {:ok, interaction} -> {:ok, interaction}
      {:error, reason} -> {:error, {:design_checkpoint_interaction_invalid, reason}}
    end
  end

  defp durable_receipt(receipt, expected_request_id, requested_deadline_unix_ms)
       when is_map(receipt) do
    with {:ok, request_id} <- receipt_value(receipt, :request_id),
         :ok <- same_request_id(request_id, expected_request_id),
         {:ok, operation_id} <- receipt_value(receipt, :operation_id),
         {:ok, operation_id} <- DesignCheckpoint.validate_operation_id(operation_id),
         {:ok, owner_deadline_unix_ms} <- receipt_value(receipt, :owner_deadline_unix_ms),
         {:ok, owner_deadline_unix_ms} <-
           DesignCheckpoint.validate_persisted_deadline(owner_deadline_unix_ms),
         :ok <- no_deadline_extension(owner_deadline_unix_ms, requested_deadline_unix_ms) do
      {:ok, operation_id, owner_deadline_unix_ms}
    end
  end

  defp durable_receipt(_receipt, _expected_request_id, _requested_deadline_unix_ms),
    do: {:error, :invalid_design_checkpoint_durable_receipt}

  defp receipt_value(receipt, key) do
    atom_value = Map.get(receipt, key)
    string_value = Map.get(receipt, Atom.to_string(key))

    cond do
      is_nil(atom_value) and is_nil(string_value) ->
        {:error, {:design_checkpoint_durable_receipt_missing, key}}

      not is_nil(atom_value) and not is_nil(string_value) and atom_value !== string_value ->
        {:error, {:design_checkpoint_durable_receipt_conflict, key}}

      true ->
        {:ok, atom_value || string_value}
    end
  end

  defp same_request_id(returned_id, expected) when returned_id === expected, do: :ok

  defp same_request_id(_returned_id, _expected),
    do: {:error, :design_checkpoint_request_id_mismatch}

  # A duplicate request may return the earlier persisted deadline, but it may
  # never widen the cutoff supplied by this Open invocation.
  defp no_deadline_extension(receipt_deadline, requested_deadline)
       when receipt_deadline <= requested_deadline,
       do: :ok

  defp no_deadline_extension(_receipt_deadline, _requested_deadline),
    do: {:error, :design_checkpoint_durable_deadline_extended}
end

defmodule Arbor.Actions.Coding.DesignCheckpoint.Await do
  @moduledoc """
  Await the durable CodingPlan v2 design approval and return a structured
  approve, rework, deny, or timeout branch.

  This action is observational and replay-safe. Open already persisted the
  durable interaction identity and deadline; Await verifies that identity
  against reconstructed evidence before asking Comms to observe the response.
  """

  use Jido.Action,
    name: "coding_design_checkpoint_await",
    description: "Await the exact durable coding design approval",
    category: "coding",
    tags: ["coding", "design_checkpoint", "approval", "pipeline_internal"],
    schema: [
      request_id: [type: :string, required: true, doc: "Expected deterministic approval id"],
      work_packet: [type: :map, required: true, doc: "Canonical CodingPlan v2 work packet"],
      packet_digest: [type: :string, required: false, doc: "Exact sha256: work-packet digest"],
      work_packet_digest: [type: :string, required: false, doc: "Alias for packet_digest"],
      task_id: [type: :string, required: true, doc: "Coding task identity"],
      task: [type: :string, required: true, doc: "Exact nonempty reviewed coding task text"],
      plan_fingerprint: [type: :string, required: true, doc: "Exact compiled plan fingerprint"],
      coding_plan_fingerprint: [
        type: :string,
        required: false,
        doc: "Canonical graph-context alias for plan_fingerprint"
      ],
      workspace_id: [type: :string, required: true, doc: "Leased workspace identity"],
      worker_session_id: [type: :string, required: true, doc: "Managed ACP worker handle"],
      provider_session_id: [type: :string, required: false, doc: "Provider session id alias"],
      worker_provider_session_id: [type: :string, required: false, doc: "Provider session id"],
      design_attempt: [type: :integer, required: true, doc: "One-based design attempt"],
      design: [
        type: :string,
        required: false,
        doc: "Legacy inline design text when design_artifact is absent"
      ],
      design_artifact: [
        type: :map,
        required: false,
        doc: "Closed design artifact descriptor for the artifact-backed path"
      ],
      design_digest: [type: :string, required: true, doc: "Exact sha256: design digest"],
      agent_id: [type: :string, required: false, doc: "Owning agent identity"],
      operation_id: [
        type: :string,
        required: true,
        doc: "Persisted durable interaction operation id"
      ],
      owner_deadline_unix_ms: [
        type: :integer,
        required: true,
        doc: "Persisted durable interaction deadline in Unix milliseconds"
      ],
      evidence: [type: :map, required: true, doc: "Exact Open evidence envelope"],
      run_deadline_unix_ms: [
        type: :integer,
        required: true,
        doc: "Executor-owned absolute run deadline in Unix milliseconds"
      ]
    ]

  alias Arbor.Actions.Coding.DesignCheckpoint
  alias Arbor.Contracts.Comms.ApprovalAnswer

  def taint_roles do
    %{
      request_id: :control,
      work_packet: :data,
      packet_digest: :control,
      work_packet_digest: :control,
      task_id: :control,
      task: :data,
      plan_fingerprint: :control,
      coding_plan_fingerprint: :control,
      workspace_id: :control,
      worker_session_id: :control,
      provider_session_id: :control,
      worker_provider_session_id: :control,
      design_attempt: :control,
      design: :data,
      design_artifact: :control,
      design_digest: :control,
      agent_id: :control,
      operation_id: :control,
      owner_deadline_unix_ms: :control,
      evidence: :control,
      run_deadline_unix_ms: :control
    }
  end

  def effect_class, do: :read
  def execution_idempotency, do: :read_only

  @impl true
  def run(params, context) when is_map(params) and is_map(context) do
    with {:ok, binding} <- DesignCheckpoint.build_binding(params, context),
         {:ok, supplied_id} <- supplied_request_id(params, context),
         {:ok, _validated_id} <- ApprovalAnswer.validate_request_id(supplied_id),
         :ok <- same_request_id(supplied_id, binding.request_id),
         {:ok, agent_id} <- required_agent_id(binding),
         {:ok, operation_id} <- supplied_operation_id(params, context),
         {:ok, supplied_evidence} <- supplied_evidence(params, context),
         :ok <- same_evidence(supplied_evidence, binding.evidence),
         {:ok, owner_deadline_unix_ms} <- supplied_owner_deadline(params, context),
         {:ok, run_deadline_unix_ms} <- run_deadline_unix_ms(params, context),
         :ok <- within_owner_deadline(owner_deadline_unix_ms, run_deadline_unix_ms),
         :ok <- verify_artifact_before_terminal(binding, context) do
      await(binding, agent_id, operation_id, owner_deadline_unix_ms, context)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def run(_params, _context), do: {:error, :invalid_design_checkpoint_input}

  # Artifact path: fail-closed verify before any approve/rework/deny/timeout.
  defp verify_artifact_before_terminal(%{path: :artifact} = binding, context) do
    case DesignCheckpoint.verify_design_artifact(
           context,
           binding,
           binding.design_artifact,
           binding.design_digest
         ) do
      {:ok, _design} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_artifact_before_terminal(_binding, _context), do: :ok

  defp supplied_request_id(params, context) do
    case Map.get(params, :request_id) || Map.get(params, "request_id") ||
           Map.get(context, :request_id) || Map.get(context, "request_id") do
      id when is_binary(id) -> {:ok, id}
      _ -> {:error, :design_checkpoint_request_id_required}
    end
  end

  defp required_agent_id(%{agent_id: agent_id}) when is_binary(agent_id) and agent_id != "",
    do: {:ok, agent_id}

  defp required_agent_id(_binding), do: {:error, :design_checkpoint_agent_id_required}

  defp same_request_id(id, id), do: :ok
  defp same_request_id(_supplied, _expected), do: {:error, :design_checkpoint_request_id_mismatch}

  defp supplied_operation_id(params, context) do
    params
    |> value(context, :operation_id)
    |> DesignCheckpoint.validate_operation_id()
  end

  defp supplied_evidence(params, context) do
    case value(params, context, :evidence) do
      evidence when is_map(evidence) -> {:ok, evidence}
      _ -> {:error, :design_checkpoint_evidence_required}
    end
  end

  defp supplied_owner_deadline(params, context) do
    params
    |> value(context, :owner_deadline_unix_ms)
    |> DesignCheckpoint.validate_persisted_deadline()
  end

  defp run_deadline_unix_ms(params, context) do
    case deadline_input(context) do
      :missing -> params |> deadline_input() |> validate_run_deadline()
      context_input -> validate_run_deadline(context_input)
    end
  end

  defp await(binding, agent_id, operation_id, owner_deadline_unix_ms, context) do
    with {:ok, comms} <- DesignCheckpoint.comms_boundary(context) do
      result =
        DesignCheckpoint.call(comms, :await_durable_interaction_response, [
          binding.request_id,
          agent_id,
          [operation_id: operation_id, owner_deadline_unix_ms: owner_deadline_unix_ms]
        ])

      settle(result, binding)
    end
  end

  defp same_evidence(evidence, expected) when evidence === expected, do: :ok
  defp same_evidence(_evidence, _expected), do: {:error, :design_checkpoint_evidence_mismatch}

  defp within_owner_deadline(owner_deadline, run_deadline) when owner_deadline <= run_deadline,
    do: :ok

  defp within_owner_deadline(_owner_deadline, _run_deadline),
    do: {:error, :design_checkpoint_owner_deadline_exceeds_run_deadline}

  defp deadline_input(source) do
    case {Map.fetch(source, :run_deadline_unix_ms), Map.fetch(source, "run_deadline_unix_ms")} do
      {:error, :error} -> :missing
      {{:ok, deadline}, :error} -> {:ok, deadline}
      {:error, {:ok, deadline}} -> {:ok, deadline}
      {{:ok, deadline}, {:ok, deadline}} -> {:ok, deadline}
      {{:ok, _atom_deadline}, {:ok, _string_deadline}} -> :conflict
    end
  end

  defp validate_run_deadline(:missing), do: {:error, :design_checkpoint_run_deadline_required}
  defp validate_run_deadline(:conflict), do: {:error, :invalid_design_checkpoint_run_deadline}

  defp validate_run_deadline({:ok, deadline}) when is_integer(deadline) and deadline > 0,
    do: {:ok, deadline}

  defp validate_run_deadline({:ok, _deadline}),
    do: {:error, :invalid_design_checkpoint_run_deadline}

  defp value(primary, secondary, key) do
    Map.get(primary, key) || Map.get(primary, Atom.to_string(key)) || Map.get(secondary, key) ||
      Map.get(secondary, Atom.to_string(key))
  end

  defp settle({:ok, response, metadata}, binding) do
    case DesignCheckpoint.normalize_response(
           response,
           metadata,
           binding.request_id,
           binding.evidence
         ) do
      {:ok, outcome, note} -> {:ok, payload(outcome, note, binding)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp settle({:error, :timeout}, binding), do: {:ok, payload("timeout", "", binding)}
  defp settle({:error, reason}, _binding), do: {:error, reason}
  defp settle(_other, _binding), do: {:error, :malformed_design_checkpoint_await_response}

  defp payload(outcome, note, binding) do
    %{
      "checkpoint_outcome" => outcome,
      "request_id" => binding.request_id,
      "note" => note,
      "evidence" => binding.evidence
    }
  end
end
