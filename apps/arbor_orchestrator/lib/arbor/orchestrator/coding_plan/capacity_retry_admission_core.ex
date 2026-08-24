defmodule Arbor.Orchestrator.CodingPlan.CapacityRetryAdmissionCore do
  @moduledoc """
  Pure projection of host-owned archived task/validation evidence into a closed
  security-regression capacity-retry proof.

  The operator shell treats a missing terminal archive as a nil first-hop proof
  (`{:ok, nil}`). This module is invoked only with a present host archive body
  and never reads the filesystem or trusts a caller-supplied capacity boolean.
  """

  alias Arbor.Orchestrator.CodingPlan.ValidationCapacityTerminal

  @proof_kind "archived_security_regression_capacity"
  @capacity_status "validation_capacity_exceeded"
  @oid_pattern ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/
  @sha256_pattern ~r/\A[0-9a-f]{64}\z/

  @capacity_termination %{
    "timed_out" => true,
    "killed" => false,
    "output_limit_exceeded" => false,
    "cancelled" => false
  }

  @type input :: %{
          archive: map(),
          task_id: String.t(),
          principal_id: String.t(),
          workspace_id: String.t()
        }

  @doc "Construct from a host archive body and exact operator identities."
  @spec new(term()) :: {:ok, input()} | {:error, :invalid_capacity_retry_proof}
  def new(params) when is_map(params) and not is_struct(params) do
    with {:ok, archive} <- required_object(params, :archive),
         {:ok, task_id} <- required_id(params, :task_id),
         {:ok, principal_id} <- required_id(params, :principal_id),
         {:ok, workspace_id} <- required_id(params, :workspace_id) do
      {:ok,
       %{
         archive: archive,
         task_id: task_id,
         principal_id: principal_id,
         workspace_id: workspace_id
       }}
    else
      _ -> {:error, :invalid_capacity_retry_proof}
    end
  end

  def new(_params), do: {:error, :invalid_capacity_retry_proof}

  @doc "Project a closed first-hop archive proof, or deny non-capacity/forged evidence."
  @spec admit(input()) :: {:ok, map()} | {:error, :not_capacity | :invalid_capacity_retry_proof}
  def admit(%{
        archive: archive,
        task_id: task_id,
        principal_id: principal_id,
        workspace_id: workspace_id
      }) do
    result = %{
      "status" => value(archive, :terminal_status),
      "canonical_status" => value(archive, :canonical_status),
      "validation" => value(archive, :validation_outputs)
    }

    cond do
      not capacity_status?(result) ->
        {:error, :not_capacity}

      ValidationCapacityTerminal.validate_consistency(result, :terminal) != :ok ->
        {:error, :invalid_capacity_retry_proof}

      true ->
        project_proof(archive, result, task_id, principal_id, workspace_id)
    end
  end

  def admit(_input), do: {:error, :invalid_capacity_retry_proof}

  @doc "JSON-clean projection of an admit result."
  @spec show({:ok, map()} | {:error, atom()}) :: map()
  def show({:ok, proof}), do: %{"decision" => "proof", "proof" => proof}
  def show({:error, reason}), do: %{"decision" => "deny", "reason" => Atom.to_string(reason)}

  defp capacity_status?(result) do
    result["status"] === @capacity_status and result["canonical_status"] === @capacity_status
  end

  defp project_proof(archive, result, task_id, principal_id, workspace_id) do
    with [report] when is_map(report) and not is_struct(report) <- result["validation"],
         true <- Enum.all?(Map.keys(report), &is_binary/1),
         true <- value(archive, :task_id) === task_id,
         :ok <- compatible_archive_workspace(archive, workspace_id),
         {:ok, tests} <- selected_tests(report),
         {:ok, digest} <- required_sha256(report, :review_attestation_digest),
         {:ok, council} <- required_sha256(report, :council_decision_digest),
         {:ok, base_commit} <- required_oid(report, :attested_base_commit),
         {:ok, candidate_commit} <- required_oid(report, :attested_candidate_commit),
         {:ok, tree_oid} <- required_oid(report, :attested_candidate_tree_oid),
         {:ok, diff} <- required_sha256(report, :attested_diff_sha256),
         true <- value(report, :reason) === @capacity_status,
         true <- value(report, :passed) === false,
         true <- value(report, :termination) === @capacity_termination do
      proof = %{
        "kind" => @proof_kind,
        "task_id" => task_id,
        "principal_id" => principal_id,
        "workspace_id" => workspace_id,
        "terminal_status" => @capacity_status,
        "canonical_status" => @capacity_status,
        "review_attestation_digest" => digest,
        "council_decision_digest" => council,
        "attested_base_commit" => base_commit,
        "attested_candidate_commit" => candidate_commit,
        "attested_candidate_tree_oid" => tree_oid,
        "attested_diff_sha256" => diff,
        "selected_tests" => tests,
        "validation_reason" => @capacity_status,
        "passed" => false,
        "termination" => @capacity_termination
      }

      {:ok, proof}
    else
      _ -> {:error, :invalid_capacity_retry_proof}
    end
  end

  # Production coding-terminal-evidence often omits top-level candidate.
  # Workspace identity comes from already-verified operator provenance.
  # A present candidate.workspace_id must match exactly; otherwise deny.
  defp compatible_archive_workspace(archive, workspace_id) do
    case value(archive, :candidate) do
      nil ->
        :ok

      candidate when is_map(candidate) and not is_struct(candidate) ->
        case value(candidate, :workspace_id) do
          ^workspace_id -> :ok
          _other -> :error
        end

      _other ->
        :error
    end
  end

  defp selected_tests(report) do
    tests = value(report, :attested_selected_tests) || value(report, :selected_tests)

    if is_list(tests) and tests != [] do
      normalized =
        Enum.map(tests, fn test ->
          %{
            "path" => value(test, :path),
            "blob_sha256" => value(test, :blob_sha256)
          }
        end)

      if Enum.all?(normalized, fn %{"path" => path, "blob_sha256" => digest} ->
           valid_id?(path) and valid_sha256?(digest)
         end) and
           normalized == Enum.sort_by(normalized, & &1["path"]) and
           Enum.uniq_by(normalized, & &1["path"]) == normalized do
        {:ok, normalized}
      else
        :error
      end
    else
      :error
    end
  end

  defp required_object(map, key) do
    case value(map, key) do
      object when is_map(object) and not is_struct(object) ->
        if Enum.all?(Map.keys(object), &is_binary/1),
          do: {:ok, object},
          else: :error

      _ ->
        :error
    end
  end

  defp required_id(map, key) do
    value = value(map, key)
    if valid_id?(value), do: {:ok, value}, else: :error
  end

  defp required_sha256(map, key) do
    value = value(map, key)
    if valid_sha256?(value), do: {:ok, value}, else: :error
  end

  defp required_oid(map, key) do
    value = value(map, key)
    if valid_oid?(value), do: {:ok, value}, else: :error
  end

  defp valid_id?(value),
    do: is_binary(value) and value != "" and String.valid?(value) and String.trim(value) == value

  defp valid_sha256?(value), do: is_binary(value) and Regex.match?(@sha256_pattern, value)
  defp valid_oid?(value), do: is_binary(value) and Regex.match?(@oid_pattern, value)

  defp value(map, key) when is_map(map) and is_atom(key) do
    case {Map.fetch(map, key), Map.fetch(map, Atom.to_string(key))} do
      {{:ok, value}, :error} -> value
      {:error, {:ok, value}} -> value
      _missing_or_ambiguous -> nil
    end
  end

  defp value(_map, _key), do: nil
end
