defmodule Arbor.Actions.Coding.ReviewAttestationSuccessorCore do
  @moduledoc """
  Pure successor admission and bounded lineage walk for security-regression
  review attestations.

  The registry shell supplies JSON-clean records, claim states, and an optional
  host-archive proof. This module never issues ids, touches the filesystem, or
  talks to processes.
  """

  @max_capacity_retry_successors 3
  @max_visited @max_capacity_retry_successors + 1
  @max_lineage_id_bytes 256
  @oid_pattern ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/
  @sha256_pattern ~r/\A[0-9a-f]{64}\z/

  @proof_keys Enum.sort(~w(
    kind
    task_id
    principal_id
    workspace_id
    terminal_status
    canonical_status
    review_attestation_digest
    council_decision_digest
    attested_base_commit
    attested_candidate_commit
    attested_candidate_tree_oid
    attested_diff_sha256
    selected_tests
    validation_reason
    passed
    termination
  ))

  @capacity_termination %{
    "timed_out" => true,
    "killed" => false,
    "output_limit_exceeded" => false,
    "cancelled" => false
  }

  @capacity_evidence_keys Enum.sort(~w(passed reason termination))

  @type decision :: {:use, String.t()} | {:mint_from, String.t()}
  @type error ::
          :attestation_already_claimed
          | :attestation_revoked
          | :capacity_retry_denied
          | :invalid_capacity_retry_proof
          | :not_authorized
          | :not_found
          | :retry_budget_exhausted
          | :successor_lineage_mismatch

  @type input :: %{
          start_id: String.t(),
          caller_task_id: String.t(),
          caller_principal_id: String.t(),
          caller_workspace_id: String.t(),
          records: %{optional(String.t()) => map()},
          states: %{optional(String.t()) => atom()},
          proof: map() | nil
        }

  @doc "System-owned successor ceiling. Not a caller option."
  @spec max_capacity_retry_successors() :: 3
  def max_capacity_retry_successors, do: @max_capacity_retry_successors

  @doc "Closed four-key security-regression capacity termination."
  @spec capacity_termination() :: map()
  def capacity_termination, do: @capacity_termination

  @doc "Construct a walk/admit input from a closed map."
  @spec new(term()) :: {:ok, input()} | {:error, :invalid_capacity_retry_proof}
  def new(params) when is_map(params) and not is_struct(params) do
    with {:ok, start_id} <- required_id(params, :start_id),
         {:ok, caller_task_id} <- required_id(params, :caller_task_id),
         {:ok, caller_principal_id} <- required_id(params, :caller_principal_id),
         {:ok, caller_workspace_id} <- required_id(params, :caller_workspace_id),
         {:ok, records} <- normalize_records(value(params, :records)),
         {:ok, states} <- normalize_states(value(params, :states)),
         {:ok, proof} <- normalize_proof(value(params, :proof)) do
      {:ok,
       %{
         start_id: start_id,
         caller_task_id: caller_task_id,
         caller_principal_id: caller_principal_id,
         caller_workspace_id: caller_workspace_id,
         records: records,
         states: states,
         proof: proof
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_capacity_retry_proof}
    end
  end

  def new(_params), do: {:error, :invalid_capacity_retry_proof}

  @doc "Decide whether to use an existing token or mint from a capacity-authorized leaf."
  @spec walk(input()) :: {:ok, decision()} | {:error, error()}
  def walk(%{
        start_id: start_id,
        caller_task_id: task_id,
        caller_principal_id: principal_id,
        caller_workspace_id: workspace_id,
        records: records,
        states: states,
        proof: proof
      }) do
    walk_from(start_id, task_id, principal_id, workspace_id, records, states, proof, [])
  end

  def walk(_input), do: {:error, :invalid_capacity_retry_proof}

  @doc "JSON-clean projection of a walk decision."
  @spec show({:ok, decision()} | {:error, error()}) :: map()
  def show({:ok, {:use, id}}), do: %{"decision" => "use", "review_attestation_id" => id}
  def show({:ok, {:mint_from, id}}), do: %{"decision" => "mint_from", "review_attestation_id" => id}
  def show({:error, reason}), do: %{"decision" => "deny", "reason" => Atom.to_string(reason)}

  @doc "True when stored Actions-owned capacity evidence is the closed marker."
  @spec valid_capacity_evidence?(term()) :: boolean()
  def valid_capacity_evidence?(evidence) when is_map(evidence) and not is_struct(evidence) do
    case capacity_evidence_keys(Map.keys(evidence)) do
      {:ok, keys} ->
        keys == @capacity_evidence_keys and
          value(evidence, :reason) === "validation_capacity_exceeded" and
          value(evidence, :passed) === false and
          value(evidence, :termination) === @capacity_termination

      :error ->
        false
    end
  end

  def valid_capacity_evidence?(_evidence), do: false

  defp walk_from(id, task_id, principal_id, workspace_id, records, states, proof, visited) do
    cond do
      id in visited ->
        {:error, :successor_lineage_mismatch}

      length(visited) >= @max_visited ->
        {:error, :retry_budget_exhausted}

      true ->
        case Map.fetch(records, id) do
          :error ->
            {:error, :not_found}

          {:ok, record} ->
            with :ok <- authorize_record(record, task_id, principal_id, workspace_id),
                 :ok <-
                   lineage_matches(
                     record,
                     task_id,
                     principal_id,
                     workspace_id,
                     records,
                     visited
                   ) do
              decide_node(
                id,
                record,
                Map.get(states, id),
                task_id,
                principal_id,
                workspace_id,
                records,
                states,
                proof,
                [id | visited]
              )
            end
        end
    end
  end

  defp decide_node(
         id,
         record,
         status,
         task_id,
         principal_id,
         workspace_id,
         records,
         states,
         proof,
         visited
       ) do
    child_id = Map.get(record, :successor_id)

    cond do
      status == :available ->
        {:ok, {:use, id}}

      status == :revoked ->
        {:error, :attestation_revoked}

      status != :claimed ->
        {:error, :not_found}

      is_binary(child_id) and child_id != "" ->
        with :ok <- ensure_child_pointer(record, child_id, records) do
          walk_from(child_id, task_id, principal_id, workspace_id, records, states, proof, visited)
        end

      retry_index(record) >= @max_capacity_retry_successors ->
        {:error, :retry_budget_exhausted}

      capacity_authorized?(record, proof) ->
        {:ok, {:mint_from, id}}

      Map.get(record, :predecessor_id) in [nil, ""] ->
        {:error, :attestation_already_claimed}

      true ->
        {:error, :capacity_retry_denied}
    end
  end

  defp authorize_record(record, task_id, principal_id, workspace_id) do
    if record.task_id === task_id and record.principal_id === principal_id and
         record.workspace_id === workspace_id do
      :ok
    else
      {:error, :not_authorized}
    end
  end

  defp lineage_matches(record, _task_id, _principal_id, _workspace_id, _records, []) do
    validate_lineage_shape(record.origin, record.retry_index, record.predecessor_id)
  end

  defp lineage_matches(record, task_id, principal_id, workspace_id, records, [prev_id | _rest]) do
    case Map.fetch(records, prev_id) do
      {:ok, prev} ->
        if record.task_id === task_id and record.principal_id === principal_id and
             record.workspace_id === workspace_id and
             material_digest(record) === material_digest(prev) and
             record.council_decision_digest === prev.council_decision_digest and
             record.predecessor_id === prev.attestation_id and
             prev.successor_id === record.attestation_id and
             record.retry_index === prev.retry_index + 1 and
             record.origin === :capacity_retry do
          :ok
        else
          {:error, :successor_lineage_mismatch}
        end

      :error ->
        {:error, :successor_lineage_mismatch}
    end
  end

  defp ensure_child_pointer(parent, child_id, records) do
    case Map.fetch(records, child_id) do
      {:ok, child} ->
        if child.predecessor_id === parent.attestation_id and
             parent.successor_id === child.attestation_id and
             child.retry_index === parent.retry_index + 1 and
             child.origin === :capacity_retry do
          :ok
        else
          {:error, :successor_lineage_mismatch}
        end

      :error ->
        {:error, :successor_lineage_mismatch}
    end
  end

  defp capacity_authorized?(record, proof) do
    valid_capacity_evidence?(Map.get(record, :capacity_evidence)) or
      first_hop_archive_authorized?(record, proof)
  end

  defp first_hop_archive_authorized?(record, proof) do
    Map.get(record, :predecessor_id) in [nil, ""] and
      Map.get(record, :successor_id) in [nil, ""] and
      valid_archive_proof?(proof) and
      proof_matches_record?(proof, record)
  end

  defp valid_archive_proof?(proof) when is_map(proof) and not is_struct(proof) do
    keys = proof |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()

    keys == @proof_keys and
      proof["kind"] === "archived_security_regression_capacity" and
      proof["terminal_status"] === "validation_capacity_exceeded" and
      proof["canonical_status"] === "validation_capacity_exceeded" and
      proof["validation_reason"] === "validation_capacity_exceeded" and
      proof["passed"] === false and
      proof["termination"] === @capacity_termination and
      valid_id?(proof["task_id"]) and
      valid_id?(proof["principal_id"]) and
      valid_id?(proof["workspace_id"]) and
      valid_sha256?(proof["review_attestation_digest"]) and
      valid_sha256?(proof["council_decision_digest"]) and
      valid_oid?(proof["attested_base_commit"]) and
      valid_oid?(proof["attested_candidate_commit"]) and
      valid_oid?(proof["attested_candidate_tree_oid"]) and
      valid_sha256?(proof["attested_diff_sha256"]) and
      valid_selected_tests?(proof["selected_tests"])
  end

  defp valid_archive_proof?(_proof), do: false

  defp proof_matches_record?(proof, record) do
    material = record.material
    tests = normalize_tests(selected_tests(material))
    proof_tests = normalize_tests(proof["selected_tests"])

    proof["task_id"] === record.task_id and
      proof["principal_id"] === record.principal_id and
      proof["workspace_id"] === record.workspace_id and
      proof["review_attestation_digest"] === material_digest(record) and
      proof["council_decision_digest"] === record.council_decision_digest and
      proof["attested_base_commit"] === scalar(material, :base_commit) and
      proof["attested_candidate_commit"] === scalar(material, :candidate_commit) and
      proof["attested_candidate_tree_oid"] === scalar(material, :candidate_tree_oid) and
      proof["attested_diff_sha256"] === scalar(material, :diff_sha256) and
      proof_tests === tests
  end

  defp normalize_records(records) when is_map(records) and not is_struct(records) do
    normalized =
      Enum.reduce_while(records, %{}, fn {id, record}, acc ->
        with true <- is_binary(id) and id != "",
             {:ok, record} <- normalize_record(record) do
          {:cont, Map.put(acc, id, record)}
        else
          _ -> {:halt, :error}
        end
      end)

    if is_map(normalized), do: {:ok, normalized}, else: {:error, :invalid_capacity_retry_proof}
  end

  defp normalize_records(_records), do: {:error, :invalid_capacity_retry_proof}

  defp normalize_record(record) when is_map(record) and not is_struct(record) do
    with {:ok, attestation_id} <- required_id(record, :attestation_id),
         {:ok, workspace_id} <- required_id(record, :workspace_id),
         {:ok, task_id} <- required_id(record, :task_id),
         {:ok, principal_id} <- required_id(record, :principal_id),
         {:ok, council_decision_digest} <- required_sha256(record, :council_decision_digest),
         {:ok, material} <- normalize_material(value(record, :material)),
         {:ok, retry_index} <- required_retry_index(record),
         {:ok, origin} <- required_origin(record),
         {:ok, predecessor_id} <- optional_lineage_id(record, :predecessor_id),
         {:ok, successor_id} <- optional_lineage_id(record, :successor_id),
         :ok <- validate_lineage_shape(origin, retry_index, predecessor_id) do
      {:ok,
       %{
         attestation_id: attestation_id,
         workspace_id: workspace_id,
         task_id: task_id,
         principal_id: principal_id,
         material: material,
         council_decision_digest: council_decision_digest,
         predecessor_id: predecessor_id,
         successor_id: successor_id,
         retry_index: retry_index,
         origin: origin,
         capacity_evidence: value(record, :capacity_evidence)
       }}
    else
      _ -> {:error, :invalid_capacity_retry_proof}
    end
  end

  defp normalize_record(_record), do: {:error, :invalid_capacity_retry_proof}

  defp normalize_material(material) when is_map(material) and not is_struct(material) do
    with {:ok, digest} <- required_sha256(material, :canonical_digest),
         {:ok, base_commit} <- required_oid(material, :base_commit),
         {:ok, candidate_commit} <- required_oid(material, :candidate_commit),
         {:ok, candidate_tree_oid} <- required_oid(material, :candidate_tree_oid),
         {:ok, diff_sha256} <- required_sha256(material, :diff_sha256),
         true <- valid_selected_tests?(selected_tests(material)) do
      {:ok,
       %{
         canonical_digest: digest,
         base_commit: base_commit,
         candidate_commit: candidate_commit,
         candidate_tree_oid: candidate_tree_oid,
         diff_sha256: diff_sha256,
         selected_tests: normalize_tests(selected_tests(material))
       }}
    else
      _ -> {:error, :invalid_capacity_retry_proof}
    end
  end

  defp normalize_material(_material), do: {:error, :invalid_capacity_retry_proof}

  defp normalize_states(states) when is_map(states) and not is_struct(states) do
    if Enum.all?(states, fn {id, status} ->
         is_binary(id) and status in [:available, :claimed, :revoked]
       end) do
      {:ok, states}
    else
      {:error, :invalid_capacity_retry_proof}
    end
  end

  defp normalize_states(_states), do: {:error, :invalid_capacity_retry_proof}

  defp normalize_proof(nil), do: {:ok, nil}

  defp normalize_proof(proof) when is_map(proof) and not is_struct(proof) do
    if Enum.all?(Map.keys(proof), &is_binary/1) do
      {:ok, proof}
    else
      {:error, :invalid_capacity_retry_proof}
    end
  end

  defp normalize_proof(_proof), do: {:error, :invalid_capacity_retry_proof}

  defp required_id(map, key) do
    value = value(map, key)
    if valid_id?(value), do: {:ok, value}, else: {:error, :invalid_capacity_retry_proof}
  end

  defp required_sha256(map, key) do
    value = value(map, key)
    if valid_sha256?(value), do: {:ok, value}, else: {:error, :invalid_capacity_retry_proof}
  end

  defp required_oid(map, key) do
    value = value(map, key)
    if valid_oid?(value), do: {:ok, value}, else: {:error, :invalid_capacity_retry_proof}
  end

  defp optional_lineage_id(map, key) when is_map(map) and is_atom(key) do
    case {Map.fetch(map, key), Map.fetch(map, Atom.to_string(key))} do
      {:error, :error} ->
        {:ok, nil}

      {{:ok, value}, :error} ->
        decode_optional_lineage_id(value)

      {:error, {:ok, value}} ->
        decode_optional_lineage_id(value)

      {_atom, _string} ->
        {:error, :invalid_capacity_retry_proof}
    end
  end

  defp optional_lineage_id(_map, _key), do: {:error, :invalid_capacity_retry_proof}

  defp decode_optional_lineage_id(nil), do: {:ok, nil}

  defp decode_optional_lineage_id(value) do
    if valid_id?(value) and byte_size(value) <= @max_lineage_id_bytes do
      {:ok, value}
    else
      {:error, :invalid_capacity_retry_proof}
    end
  end

  defp capacity_evidence_keys(keys) do
    Enum.reduce_while(keys, [], fn
      key, acc when is_atom(key) ->
        {:cont, [Atom.to_string(key) | acc]}

      key, acc when is_binary(key) ->
        if String.valid?(key), do: {:cont, [key | acc]}, else: {:halt, :error}

      _key, _acc ->
        {:halt, :error}
    end)
    |> case do
      :error -> :error
      list -> {:ok, Enum.sort(list)}
    end
  end

  defp required_retry_index(record) do
    case value(record, :retry_index) do
      index when is_integer(index) and index >= 0 and index <= @max_capacity_retry_successors ->
        {:ok, index}

      _invalid ->
        {:error, :invalid_capacity_retry_proof}
    end
  end

  defp required_origin(record) do
    case value(record, :origin) do
      :capacity_retry -> {:ok, :capacity_retry}
      "capacity_retry" -> {:ok, :capacity_retry}
      :council_issued -> {:ok, :council_issued}
      "council_issued" -> {:ok, :council_issued}
      _invalid -> {:error, :invalid_capacity_retry_proof}
    end
  end

  defp validate_lineage_shape(:council_issued, 0, nil), do: :ok

  defp validate_lineage_shape(:capacity_retry, index, predecessor_id)
       when is_integer(index) and index >= 1 and is_binary(predecessor_id) and
              predecessor_id != "",
       do: :ok

  defp validate_lineage_shape(_origin, _index, _predecessor_id),
    do: {:error, :successor_lineage_mismatch}

  defp retry_index(record), do: record.retry_index

  defp material_digest(record), do: scalar(record.material, :canonical_digest)

  defp selected_tests(material), do: value(material, :selected_tests) || []

  defp normalize_tests(tests) when is_list(tests) do
    tests
    |> Enum.map(fn test ->
      %{
        "path" => scalar(test, :path),
        "blob_sha256" => scalar(test, :blob_sha256)
      }
    end)
    |> Enum.sort_by(& &1["path"])
  end

  defp valid_selected_tests?(tests) when is_list(tests) and tests != [] do
    normalized = normalize_tests(tests)

    Enum.all?(normalized, fn %{"path" => path, "blob_sha256" => digest} ->
      valid_id?(path) and valid_sha256?(digest)
    end) and normalized == Enum.sort_by(normalized, & &1["path"]) and
      Enum.uniq_by(normalized, & &1["path"]) == normalized
  end

  defp valid_selected_tests?(_tests), do: false

  defp valid_id?(value),
    do: is_binary(value) and value != "" and String.valid?(value) and String.trim(value) == value

  defp valid_sha256?(value), do: is_binary(value) and Regex.match?(@sha256_pattern, value)
  defp valid_oid?(value), do: is_binary(value) and Regex.match?(@oid_pattern, value)

  defp scalar(map, key) when is_map(map), do: value(map, key)
  defp scalar(_map, _key), do: nil

  defp value(map, key) when is_map(map) and is_atom(key) do
    case {Map.fetch(map, key), Map.fetch(map, Atom.to_string(key))} do
      {{:ok, value}, :error} -> value
      {:error, {:ok, value}} -> value
      _missing_or_ambiguous -> nil
    end
  end

  defp value(_map, _key), do: nil
end
