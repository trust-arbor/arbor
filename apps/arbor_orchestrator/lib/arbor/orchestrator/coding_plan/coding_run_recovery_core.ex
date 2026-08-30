defmodule Arbor.Orchestrator.CodingPlan.CodingRunRecoveryCore do
  @moduledoc """
  Pure admission, error classification, and idempotence for coding-run recovery.

  No IO, no GenServer, no credential handles.
  """

  @idempotence_domain "arbor.agent.coding_run_recovery.terminal.v1"
  @coding_kind "coding_change"
  @admitted_final_outcomes MapSet.new(["success", "partial_success", "fail", "skipped"])

  @binding_keys MapSet.new(~w(
    schema_version
    task_id
    run_id
    agent_id
    execution_principal
    control_principal_id
    executor_kind
    graph_hash
    compiler_version
    artifact_identity
  ))

  @receipt_keys MapSet.new(~w(
    schema_version
    task_id
    run_id
    execution_principal
    control_principal_id
    graph_hash
    artifact_identity
    idempotence_key
    final_outcome_status
    coding_status
    canonical_status
    error
    worker_provider
    requested_model
    confirmed_model
    delivery_state
    completion_state
    worker_session_id
    worker_provider_session_id
    workspace_id
    branch
    base_commit
    commit
    commit_hash
    workspace_release_status
    plan_digest
    pipeline_digest
    manifest_digest
    node_failure_reasons
    adapter_input_digest
    decision_digest
  ))

  @adapter_input_keys MapSet.new(~w(
    schema_version
    task_id
    run_id
    program
    candidate_tree_oid
    action_result
    observed_at
  ))

  @decision_keys MapSet.new(~w(
    schema_version
    task_id
    run_id
    agent_id
    execution_principal
    control_principal_id
    executor_kind
    graph_hash
    artifact_identity
    canonical_status
    final_outcome_status
    validation_requirement
    program_digest
    candidate_tree_oid
    observed_at
    adapter_input_digest
    binding_digest
    decision_digest
  ))

  @probe_keys MapSet.new(~w(
    schema_version
    task_id
    run_id
    agent_id
    execution_principal
    control_principal_id
    executor_kind
    graph_hash
    artifact_identity
    binding_digest
  ))

  @required_validation_statuses MapSet.new(~w(
    change_committed
    pr_created
    validation_failed
    validation_capacity_exceeded
  ))

  @reviewed_validation_statuses MapSet.new(~w(
    human_review_required
    review_failed
    review_unavailable
    review_rejected
    review_requires_rework
    rework_exhausted
    approval_denied
  ))

  @non_accepting_diagnostic_statuses MapSet.new(~w(
    pipeline_error
  ))

  @adapter_input_domain "arbor.coding.terminal.adapter_input.v1"
  @decision_domain "arbor.coding.terminal.decision.v1"
  @program_domain "arbor.coding.terminal.program.v1"

  @max_id_bytes 512
  @max_status_bytes 256
  @max_failure_entries 500
  @max_node_id_bytes 256
  @max_reason_bytes 512
  @max_close_cause_depth 2
  @max_close_cause_bytes 1024

  @type error_class :: :retryable_unavailable | :authoritative_absent | :denial_or_tamper

  @spec admit(map(), map(), map(), String.t()) :: :ok | {:error, :binding_mismatch}
  def admit(binding, record, compilation, agent_id)
      when is_map(binding) and is_map(record) and is_map(compilation) and is_binary(agent_id) do
    with :ok <- closed_binding?(binding),
         :ok <- eq(binding["task_id"], record_get(record, :run_id)),
         :ok <- eq(binding["run_id"], record_get(record, :run_id)),
         :ok <- eq(binding["run_id"], binding["task_id"]),
         :ok <- eq(binding["agent_id"], agent_id),
         :ok <- eq(binding["execution_principal"], agent_id),
         :ok <- eq(binding["execution_principal"], record_get(record, :execution_principal)),
         :ok <- eq(binding["graph_hash"], record_get(record, :graph_hash)),
         :ok <- eq(binding["graph_hash"], compilation_get(compilation, "graph_hash")),
         :ok <-
           eq(binding["artifact_identity"], compilation_get(compilation, "artifact_identity")),
         :ok <- eq(binding["compiler_version"], compilation_get(compilation, "compiler_version")),
         :ok <- eq(binding["executor_kind"], @coding_kind),
         :ok <- sha256_hex?(binding["graph_hash"]),
         :ok <- sha256_hex?(binding["artifact_identity"]) do
      :ok
    else
      _ -> {:error, :binding_mismatch}
    end
  end

  def admit(_binding, _record, _compilation, _agent_id), do: {:error, :binding_mismatch}

  @spec admit_receipt(map(), map(), map(), map()) :: :ok | {:error, :binding_mismatch}
  def admit_receipt(receipt, binding, record, compilation)
      when is_map(receipt) and is_map(binding) and is_map(record) and is_map(compilation) do
    expected_key =
      idempotence_key(
        binding["task_id"],
        binding["run_id"],
        binding["graph_hash"],
        binding["artifact_identity"],
        receipt["canonical_status"] || ""
      )

    with :ok <- closed_receipt?(receipt),
         :ok <- admit(binding, record, compilation, binding["agent_id"]),
         :ok <- eq(receipt["task_id"], binding["task_id"]),
         :ok <- eq(receipt["run_id"], binding["run_id"]),
         :ok <- eq(receipt["execution_principal"], binding["execution_principal"]),
         :ok <- eq(receipt["control_principal_id"], binding["control_principal_id"]),
         :ok <- eq(receipt["graph_hash"], binding["graph_hash"]),
         :ok <- eq(receipt["artifact_identity"], binding["artifact_identity"]),
         :ok <- eq(receipt["idempotence_key"], expected_key) do
      :ok
    else
      _ -> {:error, :binding_mismatch}
    end
  end

  def admit_receipt(_receipt, _binding, _record, _compilation), do: {:error, :binding_mismatch}

  @spec closed_binding?(term()) :: :ok | {:error, :invalid_binding}
  def closed_binding?(binding) when is_map(binding) and not is_struct(binding) do
    keys = MapSet.new(Map.keys(binding))

    cond do
      not MapSet.equal?(keys, @binding_keys) ->
        {:error, :invalid_binding}

      binding["schema_version"] != 1 ->
        {:error, :invalid_binding}

      not valid_id?(binding["task_id"]) ->
        {:error, :invalid_binding}

      binding["run_id"] != binding["task_id"] ->
        {:error, :invalid_binding}

      not valid_id?(binding["agent_id"]) ->
        {:error, :invalid_binding}

      not valid_id?(binding["execution_principal"]) ->
        {:error, :invalid_binding}

      not valid_id?(binding["control_principal_id"]) ->
        {:error, :invalid_binding}

      binding["executor_kind"] != @coding_kind ->
        {:error, :invalid_binding}

      sha256_hex?(binding["graph_hash"]) != :ok ->
        {:error, :invalid_binding}

      sha256_hex?(binding["artifact_identity"]) != :ok ->
        {:error, :invalid_binding}

      not valid_compiler_version?(binding["compiler_version"]) ->
        {:error, :invalid_binding}

      true ->
        :ok
    end
  end

  def closed_binding?(_), do: {:error, :invalid_binding}

  @spec closed_receipt?(term()) :: :ok | {:error, :invalid_receipt}
  def closed_receipt?(receipt) when is_map(receipt) and not is_struct(receipt) do
    keys = MapSet.new(Map.keys(receipt))

    cond do
      not MapSet.equal?(keys, @receipt_keys) ->
        {:error, :invalid_receipt}

      receipt["schema_version"] != 1 ->
        {:error, :invalid_receipt}

      not valid_id?(receipt["task_id"]) ->
        {:error, :invalid_receipt}

      receipt["run_id"] != receipt["task_id"] ->
        {:error, :invalid_receipt}

      not valid_id?(receipt["execution_principal"]) ->
        {:error, :invalid_receipt}

      not valid_id?(receipt["control_principal_id"]) ->
        {:error, :invalid_receipt}

      sha256_hex?(receipt["graph_hash"]) != :ok ->
        {:error, :invalid_receipt}

      sha256_hex?(receipt["artifact_identity"]) != :ok ->
        {:error, :invalid_receipt}

      sha256_hex?(receipt["idempotence_key"]) != :ok ->
        {:error, :invalid_receipt}

      not valid_status?(receipt["final_outcome_status"]) ->
        {:error, :invalid_receipt}

      not valid_status?(receipt["coding_status"]) ->
        {:error, :invalid_receipt}

      not valid_status?(receipt["canonical_status"]) ->
        {:error, :invalid_receipt}

      not valid_optional_id?(receipt["worker_session_id"]) ->
        {:error, :invalid_receipt}

      not valid_optional_id?(receipt["worker_provider_session_id"]) ->
        {:error, :invalid_receipt}

      not valid_optional_id?(receipt["workspace_id"]) ->
        {:error, :invalid_receipt}

      not valid_optional_id?(receipt["base_commit"]) ->
        {:error, :invalid_receipt}

      not valid_optional_id?(receipt["commit"]) ->
        {:error, :invalid_receipt}

      not valid_optional_id?(receipt["commit_hash"]) ->
        {:error, :invalid_receipt}

      not valid_status?(receipt["error"]) ->
        {:error, :invalid_receipt}

      not valid_status?(receipt["worker_provider"]) ->
        {:error, :invalid_receipt}

      not valid_status?(receipt["requested_model"]) ->
        {:error, :invalid_receipt}

      not valid_status?(receipt["confirmed_model"]) ->
        {:error, :invalid_receipt}

      not valid_status?(receipt["delivery_state"]) ->
        {:error, :invalid_receipt}

      not valid_status?(receipt["completion_state"]) ->
        {:error, :invalid_receipt}

      not valid_status?(receipt["branch"]) ->
        {:error, :invalid_receipt}

      not valid_status?(receipt["workspace_release_status"]) ->
        {:error, :invalid_receipt}

      not valid_optional_digest?(receipt["plan_digest"]) ->
        {:error, :invalid_receipt}

      not valid_optional_digest?(receipt["pipeline_digest"]) ->
        {:error, :invalid_receipt}

      not valid_optional_digest?(receipt["manifest_digest"]) ->
        {:error, :invalid_receipt}

      not valid_failure_map?(receipt["node_failure_reasons"]) ->
        {:error, :invalid_receipt}

      not valid_optional_digest?(receipt["adapter_input_digest"]) ->
        {:error, :invalid_receipt}

      sha256_hex?(receipt["decision_digest"]) != :ok ->
        {:error, :invalid_receipt}

      true ->
        :ok
    end
  end

  def closed_receipt?(_), do: {:error, :invalid_receipt}

  @spec idempotence_key(String.t(), String.t(), String.t(), String.t(), String.t()) :: String.t()
  def idempotence_key(task_id, run_id, graph_hash, artifact_identity, canonical_status)
      when is_binary(task_id) and is_binary(run_id) and is_binary(graph_hash) and
             is_binary(artifact_identity) and is_binary(canonical_status) do
    framed_digest([
      @idempotence_domain,
      task_id,
      run_id,
      graph_hash,
      artifact_identity,
      canonical_status
    ])
  end

  @spec binding_digest(map()) :: {:ok, String.t()} | {:error, :invalid_binding}
  def binding_digest(binding) when is_map(binding) do
    with :ok <- closed_binding?(binding) do
      {:ok,
       framed_digest([
         "arbor.coding.run.binding.v1",
         binding["task_id"],
         binding["run_id"],
         binding["agent_id"],
         binding["execution_principal"],
         binding["control_principal_id"],
         binding["executor_kind"],
         binding["graph_hash"],
         binding["compiler_version"],
         binding["artifact_identity"]
       ])}
    end
  end

  def binding_digest(_), do: {:error, :invalid_binding}

  @doc """
  Status-only display helper. Not an admission oracle.

  Publish, recover, and `closed_decision?/1` must use `evidence_state/1` plus
  `expected_requirement/2`.
  """
  @spec validation_requirement(term()) :: String.t()
  def validation_requirement(status) when is_binary(status) do
    if MapSet.member?(@required_validation_statuses, status),
      do: "required",
      else: "not_applicable"
  end

  def validation_requirement(_), do: "not_applicable"

  @spec evidence_state(map()) :: :none | :complete | :partial
  def evidence_state(decision) when is_map(decision) and not is_struct(decision) do
    classify_slots([
      digest_slot(decision["program_digest"]),
      digest_slot(decision["adapter_input_digest"]),
      oid_slot(decision["candidate_tree_oid"]),
      observed_slot(decision["observed_at"])
    ])
  end

  def evidence_state(_), do: :partial

  @spec expected_requirement(term(), :none | :complete | :partial) ::
          {:ok, String.t()}
          | {:error,
             :partial_validation_evidence | :missing_validation_evidence | :invalid_decision}
  def expected_requirement(status, evidence_state)
      when is_binary(status) and evidence_state in [:none, :complete, :partial] do
    cond do
      MapSet.member?(@non_accepting_diagnostic_statuses, status) ->
        {:ok, "not_applicable"}

      evidence_state == :partial ->
        {:error, :partial_validation_evidence}

      MapSet.member?(@required_validation_statuses, status) and evidence_state == :complete ->
        {:ok, "required"}

      MapSet.member?(@required_validation_statuses, status) ->
        {:error, :missing_validation_evidence}

      MapSet.member?(@reviewed_validation_statuses, status) and evidence_state == :complete ->
        {:ok, "required"}

      MapSet.member?(@reviewed_validation_statuses, status) and evidence_state == :none ->
        {:ok, "not_applicable"}

      evidence_state == :none ->
        {:ok, "not_applicable"}

      evidence_state == :complete ->
        {:error, :invalid_decision}

      true ->
        {:error, :invalid_decision}
    end
  end

  def expected_requirement(_status, _evidence_state), do: {:error, :invalid_decision}

  @spec producer_evidence_state(term(), term(), term(), term()) :: :none | :complete | :partial
  def producer_evidence_state(program, tree_oid, observed_at, action_result) do
    classify_slots([
      producer_slot(program, &producer_program?/1),
      producer_slot(tree_oid, &producer_oid?/1),
      producer_slot(observed_at, &producer_observed?/1),
      producer_slot(action_result, &producer_result?/1)
    ])
  end

  @spec combine_close_result(term(), term()) :: term()
  def combine_close_result(:ok, {:ok, value}), do: {:ok, value}
  def combine_close_result(:ok, {:error, reason}), do: {:error, bounded_close_cause(reason)}
  def combine_close_result(:ok, other), do: other

  def combine_close_result({:error, close_reason}, {:ok, _value}) do
    {:error, {:authority_close_failed, bounded_close_cause(close_reason), :resume_succeeded}}
  end

  def combine_close_result({:error, close_reason}, {:error, reason}) do
    {:error,
     {:authority_close_failed, bounded_close_cause(close_reason), bounded_close_cause(reason)}}
  end

  def combine_close_result({:error, close_reason}, other) do
    {:error,
     {:authority_close_failed, bounded_close_cause(close_reason), bounded_close_cause(other)}}
  end

  def combine_close_result(_close_result, original), do: original

  @spec bounded_close_cause(term()) :: term()
  def bounded_close_cause(reason) do
    bounded = bound_close_cause(reason, 0)

    if close_cause_within_budget?(bounded) do
      bounded
    else
      :unprovable_recovery
    end
  end

  defp bound_close_cause(_reason, depth) when depth > @max_close_cause_depth,
    do: :unprovable_recovery

  defp bound_close_cause(:resume_succeeded, _depth), do: :resume_succeeded
  defp bound_close_cause(reason, _depth) when is_atom(reason), do: reason

  defp bound_close_cause(reason, _depth) when is_binary(reason),
    do: utf8_truncate(reason, @max_status_bytes)

  defp bound_close_cause({tag, inner}, depth)
       when is_atom(tag) and depth < @max_close_cause_depth,
       do: {tag, bound_close_cause(inner, depth + 1)}

  defp bound_close_cause({tag, a, b}, depth)
       when is_atom(tag) and depth < @max_close_cause_depth,
       do: {tag, bound_close_cause(a, depth + 1), bound_close_cause(b, depth + 1)}

  defp bound_close_cause({tag, a, b, c}, depth)
       when is_atom(tag) and depth < @max_close_cause_depth,
       do:
         {tag, bound_close_cause(a, depth + 1), bound_close_cause(b, depth + 1),
          bound_close_cause(c, depth + 1)}

  defp bound_close_cause(_reason, _depth), do: :unprovable_recovery

  defp close_cause_within_budget?(term), do: close_cause_bytes(term) <= @max_close_cause_bytes

  defp close_cause_bytes(term) when is_atom(term), do: 1

  defp close_cause_bytes(term) when is_binary(term), do: byte_size(term)

  defp close_cause_bytes(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(0, fn part, acc -> acc + close_cause_bytes(part) end)
  end

  defp close_cause_bytes(_), do: @max_close_cause_bytes + 1

  @spec canonical_json(term()) :: {:ok, term()} | {:error, :invalid_json}
  def canonical_json(value) do
    case do_canonical_json(value) do
      {:ok, canonical} -> {:ok, canonical}
      :error -> {:error, :invalid_json}
    end
  end

  @spec closed_adapter_input?(term()) :: :ok | {:error, :invalid_adapter_input}
  def closed_adapter_input?(adapter) when is_map(adapter) and not is_struct(adapter) do
    keys = MapSet.new(Map.keys(adapter))

    cond do
      not MapSet.equal?(keys, @adapter_input_keys) ->
        {:error, :invalid_adapter_input}

      adapter["schema_version"] != 1 ->
        {:error, :invalid_adapter_input}

      not valid_id?(adapter["task_id"]) ->
        {:error, :invalid_adapter_input}

      adapter["run_id"] != adapter["task_id"] ->
        {:error, :invalid_adapter_input}

      not adapter_program?(adapter["program"]) ->
        {:error, :invalid_adapter_input}

      not match?({:ok, _}, canonical_json(adapter["program"])) ->
        {:error, :invalid_adapter_input}

      not valid_optional_id?(adapter["candidate_tree_oid"]) or adapter["candidate_tree_oid"] == "" ->
        {:error, :invalid_adapter_input}

      not adapter_action_result?(adapter["action_result"]) ->
        {:error, :invalid_adapter_input}

      not match?({:ok, _}, canonical_json(adapter["action_result"])) ->
        {:error, :invalid_adapter_input}

      not valid_status?(adapter["observed_at"]) or adapter["observed_at"] in [nil, ""] ->
        {:error, :invalid_adapter_input}

      true ->
        :ok
    end
  end

  def closed_adapter_input?(_), do: {:error, :invalid_adapter_input}

  @spec adapter_input_digest(map()) :: {:ok, String.t()} | {:error, :invalid_adapter_input}
  def adapter_input_digest(adapter) when is_map(adapter) do
    with :ok <- closed_adapter_input?(adapter),
         {:ok, json} <- compact_canonical_json(adapter_four_tuple(adapter)) do
      {:ok, framed_digest([@adapter_input_domain, json])}
    else
      {:error, :invalid_adapter_input} = error -> error
      _ -> {:error, :invalid_adapter_input}
    end
  end

  def adapter_input_digest(_), do: {:error, :invalid_adapter_input}

  @spec program_digest(term()) :: {:ok, String.t()} | {:error, :invalid_adapter_input}
  def program_digest(program) when is_map(program) and not is_struct(program) do
    case compact_canonical_json(program) do
      {:ok, json} -> {:ok, framed_digest([@program_domain, json])}
      _ -> {:error, :invalid_adapter_input}
    end
  end

  def program_digest(_), do: {:error, :invalid_adapter_input}

  @spec closed_decision?(term()) :: :ok | {:error, :invalid_decision}
  def closed_decision?(decision) when is_map(decision) and not is_struct(decision) do
    keys = MapSet.new(Map.keys(decision))
    requirement = decision["validation_requirement"]
    evidence_state = evidence_state(decision)

    cond do
      not MapSet.equal?(keys, @decision_keys) ->
        {:error, :invalid_decision}

      decision["schema_version"] != 1 ->
        {:error, :invalid_decision}

      not valid_id?(decision["task_id"]) ->
        {:error, :invalid_decision}

      decision["run_id"] != decision["task_id"] ->
        {:error, :invalid_decision}

      not valid_id?(decision["agent_id"]) ->
        {:error, :invalid_decision}

      decision["execution_principal"] != decision["agent_id"] ->
        {:error, :invalid_decision}

      not valid_id?(decision["control_principal_id"]) ->
        {:error, :invalid_decision}

      decision["executor_kind"] != @coding_kind ->
        {:error, :invalid_decision}

      sha256_hex?(decision["graph_hash"]) != :ok ->
        {:error, :invalid_decision}

      sha256_hex?(decision["artifact_identity"]) != :ok ->
        {:error, :invalid_decision}

      not valid_status?(decision["canonical_status"]) or decision["canonical_status"] in [nil, ""] ->
        {:error, :invalid_decision}

      not valid_status?(decision["final_outcome_status"]) or
          decision["final_outcome_status"] in [nil, ""] ->
        {:error, :invalid_decision}

      sha256_hex?(decision["binding_digest"]) != :ok ->
        {:error, :invalid_decision}

      sha256_hex?(decision["decision_digest"]) != :ok ->
        {:error, :invalid_decision}

      true ->
        case expected_requirement(decision["canonical_status"], evidence_state) do
          {:ok, expected} when requirement == expected and expected == "required" ->
            :ok

          {:ok, expected} when requirement == expected and expected == "not_applicable" ->
            :ok

          _ ->
            {:error, :invalid_decision}
        end
    end
  end

  def closed_decision?(_), do: {:error, :invalid_decision}

  @spec decision_digest(map()) :: {:ok, String.t()} | {:error, :invalid_decision}
  def decision_digest(decision) when is_map(decision) do
    parts = [
      @decision_domain,
      decision["task_id"],
      decision["run_id"],
      decision["agent_id"],
      decision["execution_principal"],
      decision["control_principal_id"],
      decision["executor_kind"],
      decision["graph_hash"],
      decision["artifact_identity"],
      decision["canonical_status"],
      decision["final_outcome_status"],
      decision["validation_requirement"],
      decision["program_digest"],
      decision["adapter_input_digest"],
      decision["binding_digest"]
    ]

    if Enum.all?(parts, &is_binary/1) do
      {:ok, framed_digest(parts)}
    else
      {:error, :invalid_decision}
    end
  end

  def decision_digest(_), do: {:error, :invalid_decision}

  @spec closed_probe_projection?(term()) :: :ok | {:error, :invalid_probe}
  def closed_probe_projection?(projection)
      when is_map(projection) and not is_struct(projection) do
    keys = MapSet.new(Map.keys(projection))

    cond do
      not MapSet.equal?(keys, @probe_keys) ->
        {:error, :invalid_probe}

      projection["schema_version"] != 1 ->
        {:error, :invalid_probe}

      not valid_id?(projection["task_id"]) ->
        {:error, :invalid_probe}

      projection["run_id"] != projection["task_id"] ->
        {:error, :invalid_probe}

      not valid_id?(projection["agent_id"]) ->
        {:error, :invalid_probe}

      projection["execution_principal"] != projection["agent_id"] ->
        {:error, :invalid_probe}

      not valid_id?(projection["control_principal_id"]) ->
        {:error, :invalid_probe}

      projection["executor_kind"] != @coding_kind ->
        {:error, :invalid_probe}

      sha256_hex?(projection["graph_hash"]) != :ok ->
        {:error, :invalid_probe}

      sha256_hex?(projection["artifact_identity"]) != :ok ->
        {:error, :invalid_probe}

      sha256_hex?(projection["binding_digest"]) != :ok ->
        {:error, :invalid_probe}

      true ->
        :ok
    end
  end

  def closed_probe_projection?(_), do: {:error, :invalid_probe}

  @spec probe_projection(map()) :: {:ok, map()} | {:error, term()}
  def probe_projection(binding) when is_map(binding) do
    with :ok <- closed_binding?(binding),
         {:ok, digest} <- binding_digest(binding) do
      {:ok,
       %{
         "schema_version" => 1,
         "task_id" => binding["task_id"],
         "run_id" => binding["run_id"],
         "agent_id" => binding["agent_id"],
         "execution_principal" => binding["execution_principal"],
         "control_principal_id" => binding["control_principal_id"],
         "executor_kind" => binding["executor_kind"],
         "graph_hash" => binding["graph_hash"],
         "artifact_identity" => binding["artifact_identity"],
         "binding_digest" => digest
       }}
    end
  end

  def probe_projection(_), do: {:error, :invalid_binding}

  @spec admit_decision(map(), map()) :: :ok | {:error, :binding_mismatch}
  def admit_decision(decision, binding) when is_map(decision) and is_map(binding) do
    with :ok <- closed_decision?(decision),
         :ok <- closed_binding?(binding),
         {:ok, expected_binding} <- binding_digest(binding),
         {:ok, expected_decision} <- decision_digest(decision),
         :ok <- eq(decision["task_id"], binding["task_id"]),
         :ok <- eq(decision["run_id"], binding["run_id"]),
         :ok <- eq(decision["agent_id"], binding["agent_id"]),
         :ok <- eq(decision["execution_principal"], binding["execution_principal"]),
         :ok <- eq(decision["control_principal_id"], binding["control_principal_id"]),
         :ok <- eq(decision["executor_kind"], binding["executor_kind"]),
         :ok <- eq(decision["graph_hash"], binding["graph_hash"]),
         :ok <- eq(decision["artifact_identity"], binding["artifact_identity"]),
         :ok <- eq(decision["binding_digest"], expected_binding),
         :ok <- eq(decision["decision_digest"], expected_decision) do
      :ok
    else
      _ -> {:error, :binding_mismatch}
    end
  end

  def admit_decision(_decision, _binding), do: {:error, :binding_mismatch}

  @spec admit_terminal_identity(map(), map(), map()) :: :ok | {:error, :binding_mismatch}
  def admit_terminal_identity(binding, decision, receipt)
      when is_map(binding) and is_map(decision) and is_map(receipt) do
    with :ok <- admit_decision(decision, binding),
         :ok <- closed_receipt?(receipt),
         :ok <- eq(receipt["task_id"], binding["task_id"]),
         :ok <- eq(receipt["run_id"], binding["run_id"]),
         :ok <- eq(receipt["execution_principal"], binding["execution_principal"]),
         :ok <- eq(receipt["control_principal_id"], binding["control_principal_id"]),
         :ok <- eq(receipt["graph_hash"], binding["graph_hash"]),
         :ok <- eq(receipt["artifact_identity"], binding["artifact_identity"]),
         :ok <- eq(receipt["canonical_status"], decision["canonical_status"]),
         :ok <- eq(receipt["final_outcome_status"], decision["final_outcome_status"]),
         :ok <-
           same_binary(receipt["adapter_input_digest"], decision["adapter_input_digest"]),
         :ok <- eq(receipt["decision_digest"], decision["decision_digest"]) do
      :ok
    else
      _ -> {:error, :binding_mismatch}
    end
  end

  def admit_terminal_identity(_binding, _decision, _receipt), do: {:error, :binding_mismatch}

  @spec admit_adapter_input(map(), map()) :: :ok | {:error, :binding_mismatch}
  def admit_adapter_input(decision, adapter) when is_map(decision) and is_map(adapter) do
    with :ok <- closed_decision?(decision),
         :ok <- closed_adapter_input?(adapter),
         {:ok, digest} <- adapter_input_digest(adapter),
         :ok <- eq(adapter["task_id"], decision["task_id"]),
         :ok <- eq(adapter["run_id"], decision["run_id"]),
         :ok <- eq(adapter["candidate_tree_oid"], decision["candidate_tree_oid"]),
         :ok <- eq(adapter["observed_at"], decision["observed_at"]),
         :ok <- eq(decision["adapter_input_digest"], digest),
         {:ok, program_digest} <- program_digest(adapter["program"]),
         :ok <- eq(decision["program_digest"], program_digest),
         :ok <- require_adapter_when_required(decision) do
      :ok
    else
      _ -> {:error, :binding_mismatch}
    end
  end

  def admit_adapter_input(_decision, _adapter), do: {:error, :binding_mismatch}

  @spec admit_executor_result(map(), map(), map()) :: :ok | {:error, :binding_mismatch}
  def admit_executor_result(receipt, decision, result)
      when is_map(receipt) and is_map(decision) and is_map(result) do
    status = result["status"] || result[:status]
    canonical = result["canonical_status"] || result[:canonical_status] || status

    with :ok <- closed_receipt?(receipt),
         :ok <- closed_decision?(decision),
         :ok <- eq(status, receipt["coding_status"]),
         :ok <- eq(canonical, receipt["canonical_status"]),
         :ok <- eq(canonical, decision["canonical_status"]) do
      :ok
    else
      _ -> {:error, :binding_mismatch}
    end
  end

  def admit_executor_result(_receipt, _decision, _result), do: {:error, :binding_mismatch}

  @spec utf8_truncate(term(), pos_integer()) :: String.t()
  def utf8_truncate(value, max) when is_binary(value) and is_integer(max) and max > 0 do
    cond do
      not String.valid?(value) ->
        ""

      byte_size(value) <= max ->
        value

      true ->
        value
        |> String.graphemes()
        |> Enum.reduce_while("", fn grapheme, acc ->
          next = acc <> grapheme

          if byte_size(next) <= max do
            {:cont, next}
          else
            {:halt, acc}
          end
        end)
    end
  end

  def utf8_truncate(_value, _max), do: ""

  @spec admitted_final_outcome?(term()) :: boolean()
  def admitted_final_outcome?(status) when is_atom(status),
    do: admitted_final_outcome?(Atom.to_string(status))

  def admitted_final_outcome?(status) when is_binary(status),
    do: MapSet.member?(@admitted_final_outcomes, status)

  def admitted_final_outcome?(_), do: false

  @spec classify_resume_error(term(), keyword()) :: error_class()
  def classify_resume_error(reason, opts \\ []) do
    secret_derived? = Keyword.get(opts, :secret_derived?, false) == true

    cond do
      denial_or_tamper?(reason, secret_derived?) ->
        :denial_or_tamper

      retryable_unavailable?(reason) ->
        :retryable_unavailable

      true ->
        :authoritative_absent
    end
  end

  @spec classify_durable_read(term()) :: :ok | :not_found | :malformed | :unavailable
  def classify_durable_read({:ok, value}) when is_map(value), do: :ok
  def classify_durable_read({:error, :not_found}), do: :not_found
  def classify_durable_read({:error, :malformed}), do: :malformed
  def classify_durable_read({:error, :invalid_binding}), do: :malformed
  def classify_durable_read({:error, :invalid_receipt}), do: :malformed
  def classify_durable_read({:error, :invalid_adapter_input}), do: :malformed
  def classify_durable_read({:error, :invalid_decision}), do: :malformed
  def classify_durable_read({:error, :invalid_probe}), do: :malformed
  def classify_durable_read({:error, :unavailable}), do: :unavailable
  def classify_durable_read({:error, :journal_unavailable}), do: :unavailable
  def classify_durable_read({:error, :store_unavailable}), do: :unavailable
  def classify_durable_read({:error, {:store_unavailable, _}}), do: :unavailable
  def classify_durable_read({:error, :eio}), do: :unavailable
  def classify_durable_read(nil), do: :not_found
  def classify_durable_read({:error, _}), do: :unavailable
  def classify_durable_read(_), do: :unavailable

  defp denial_or_tamper?(:principal_mismatch, _), do: true
  defp denial_or_tamper?({:principal_mismatch, _}, _), do: true
  defp denial_or_tamper?(:unauthorized_resume, true), do: true
  defp denial_or_tamper?({:unauthorized_resume, _}, true), do: true
  defp denial_or_tamper?(:checkpoint_hmac_invalid, _), do: true
  defp denial_or_tamper?(:tampered, _), do: true
  defp denial_or_tamper?(:checkpoint_hmac_missing, true), do: true
  defp denial_or_tamper?(:checkpoint_key_mismatch, _), do: true
  defp denial_or_tamper?(:checkpoint_run_id_mismatch, _), do: true
  defp denial_or_tamper?(:graph_changed, _), do: true
  defp denial_or_tamper?({:parse_error, _}, _), do: true
  defp denial_or_tamper?({:compile_error, _}, _), do: true
  defp denial_or_tamper?({:invalid_graph, _}, _), do: true
  defp denial_or_tamper?(:binding_mismatch, _), do: true
  defp denial_or_tamper?(:unprovable_recovery, _), do: true
  defp denial_or_tamper?(:stale_or_duplicate_terminal, _), do: true
  defp denial_or_tamper?(:missing_or_nonterminal_final_outcome, _), do: true
  defp denial_or_tamper?(_, _), do: false

  defp retryable_unavailable?(:journal_unavailable), do: true
  defp retryable_unavailable?(:store_unavailable), do: true
  defp retryable_unavailable?({:store_unavailable, _}), do: true
  defp retryable_unavailable?(:broker_unavailable), do: true
  defp retryable_unavailable?(:security_unavailable), do: true
  defp retryable_unavailable?(:authentication_unavailable), do: true
  defp retryable_unavailable?(:identity_required_for_resume), do: true
  defp retryable_unavailable?(:no_signing_key), do: true
  defp retryable_unavailable?({:durable_checkpoint, _}), do: true
  defp retryable_unavailable?(:unavailable), do: true
  defp retryable_unavailable?(:eio), do: true
  defp retryable_unavailable?(:control_inventory_unavailable), do: true
  defp retryable_unavailable?(:checkpoint_not_found), do: false
  defp retryable_unavailable?({:unauthorized_resume, _}), do: false
  defp retryable_unavailable?(_), do: false

  defp eq(left, right) when is_binary(left) and left != "" and left == right, do: :ok
  defp eq(_left, _right), do: :error

  defp same_binary(left, right) when is_binary(left) and is_binary(right) and left == right,
    do: :ok

  defp same_binary(_left, _right), do: :error

  defp record_get(record, key) when is_map(record) do
    Map.get(record, key, Map.get(record, Atom.to_string(key)))
  end

  defp compilation_get(compilation, key) when is_map(compilation), do: Map.get(compilation, key)

  defp valid_id?(value) when is_binary(value),
    do: String.valid?(value) and byte_size(value) > 0 and byte_size(value) <= @max_id_bytes

  defp valid_id?(_), do: false

  defp valid_optional_id?(value) when is_binary(value),
    do: String.valid?(value) and byte_size(value) <= @max_id_bytes

  defp valid_optional_id?(_), do: false

  defp valid_compiler_version?(value) when is_binary(value),
    do: String.valid?(value) and byte_size(value) > 0 and byte_size(value) <= 128

  defp valid_compiler_version?(_), do: false

  defp valid_optional_digest?(""), do: true
  defp valid_optional_digest?(value), do: sha256_hex?(value) == :ok

  defp valid_status?(value) when is_binary(value),
    do: String.valid?(value) and byte_size(value) <= @max_status_bytes

  defp valid_status?(nil), do: true
  defp valid_status?(_), do: false

  defp valid_failure_map?(reasons) when is_map(reasons) and not is_struct(reasons) do
    map_size(reasons) <= @max_failure_entries and
      Enum.all?(reasons, fn {node_id, reason} ->
        is_binary(node_id) and byte_size(node_id) <= @max_node_id_bytes and
          is_binary(reason) and byte_size(reason) <= @max_reason_bytes
      end)
  end

  defp valid_failure_map?(reasons) when reasons in [nil, %{}], do: true
  defp valid_failure_map?(_), do: false

  defp sha256_hex?(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, value), do: :ok, else: :error
  end

  defp sha256_hex?(_), do: :error

  defp framed_digest(parts) when is_list(parts) do
    iodata =
      Enum.map(parts, fn part ->
        bin = if is_binary(part), do: part, else: ""
        [<<byte_size(bin)::unsigned-32>>, bin]
      end)

    iodata
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp adapter_program?(program) when is_map(program) and not is_struct(program), do: true
  defp adapter_program?(_), do: false

  defp adapter_action_result?(result) when is_map(result) and not is_struct(result), do: true
  defp adapter_action_result?(_), do: false

  defp adapter_four_tuple(adapter) do
    %{
      "program" => adapter["program"],
      "candidate_tree_oid" => adapter["candidate_tree_oid"],
      "action_result" => adapter["action_result"],
      "observed_at" => adapter["observed_at"]
    }
  end

  defp require_adapter_when_required(%{"validation_requirement" => "required"}), do: :ok
  defp require_adapter_when_required(_), do: :error

  defp compact_canonical_json(value) do
    with {:ok, canonical} <- canonical_json(value) do
      Jason.encode(canonical)
    else
      _ -> {:error, :invalid_json}
    end
  rescue
    _ -> {:error, :invalid_json}
  end

  defp do_canonical_json(map) when is_map(map) and not is_struct(map) do
    keys = Map.keys(map)

    if Enum.all?(keys, &(is_binary(&1) and String.valid?(&1))) do
      keys
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, fn key, {:ok, acc} ->
        case do_canonical_json(Map.fetch!(map, key)) do
          {:ok, value} -> {:cont, {:ok, [{key, value} | acc]}}
          :error -> {:halt, :error}
        end
      end)
      |> case do
        {:ok, pairs} -> {:ok, Jason.OrderedObject.new(Enum.reverse(pairs))}
        :error -> :error
      end
    else
      :error
    end
  end

  defp do_canonical_json(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case do_canonical_json(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  defp do_canonical_json(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp do_canonical_json(_), do: :error

  defp classify_slots(slots) when is_list(slots) do
    cond do
      Enum.all?(slots, &(&1 == :absent)) -> :none
      Enum.all?(slots, &(&1 == :valid)) -> :complete
      true -> :partial
    end
  end

  defp digest_slot(""), do: :absent

  defp digest_slot(value) when is_binary(value) do
    if sha256_hex?(value) == :ok, do: :valid, else: :invalid
  end

  defp digest_slot(_), do: :invalid

  defp oid_slot(""), do: :absent

  defp oid_slot(value) when is_binary(value) do
    if valid_id?(value), do: :valid, else: :invalid
  end

  defp oid_slot(_), do: :invalid

  defp observed_slot(""), do: :absent

  defp observed_slot(value) when is_binary(value) do
    if valid_status?(value) and value != "", do: :valid, else: :invalid
  end

  defp observed_slot(_), do: :invalid

  defp producer_slot(value, validator) when is_function(validator, 1) do
    cond do
      producer_absent?(value) -> :absent
      validator.(value) -> :valid
      true -> :invalid
    end
  end

  defp producer_absent?(nil), do: true
  defp producer_absent?(""), do: true
  defp producer_absent?(_), do: false

  defp producer_program?(program) when is_map(program) and not is_struct(program),
    do: match?({:ok, _}, canonical_json(program))

  defp producer_program?(_), do: false

  defp producer_oid?(oid) when is_binary(oid), do: valid_id?(oid)
  defp producer_oid?(_), do: false

  defp producer_observed?(value) when is_binary(value),
    do: valid_status?(value) and value != ""

  defp producer_observed?(_), do: false

  defp producer_result?(result) when is_map(result) and not is_struct(result),
    do: match?({:ok, _}, canonical_json(result))

  defp producer_result?(_), do: false
end
