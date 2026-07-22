defmodule Arbor.Actions.Coding.WorkspaceReconciliationProjection do
  @moduledoc false

  @schema_version 1
  @max_id_bytes 256
  @max_path_bytes 4_096
  @max_branch_bytes 512
  @max_commit_bytes 128
  @max_retry_count 32
  @max_count 1_000_000

  @resource_types %{
    live: "live_workspace_lease",
    retained: "retained_workspace_record",
    validation: "validation_resource",
    quarantine: "quarantine"
  }

  @type_order %{
    "live_workspace_lease" => 0,
    "retained_workspace_record" => 1,
    "validation_resource" => 2,
    "quarantine" => 3
  }

  @doc false
  @spec from_registry_state(map(), String.t() | nil, String.t() | nil, pos_integer()) :: map()
  def from_registry_state(state, task_id, principal_id, max_items)
      when is_map(state) and is_integer(max_items) and max_items > 0 do
    {live, live_quarantine} = project_collection(state, :leases, :live)
    {retained, retained_quarantine} = project_collection(state, :retained_by_id, :retained)
    {blockers, blocker_quarantine} = project_collection(state, :retention_blockers, :retained)

    workspace_join = join_index(live ++ retained ++ blockers)

    {validation, validation_quarantine} =
      project_validation_collection(state, workspace_join)

    malformed_quarantine =
      quarantine_for_malformed("registry_live_leases", live_quarantine) ++
        quarantine_for_malformed("registry_retained_records", retained_quarantine) ++
        quarantine_for_malformed("registry_retention_blockers", blocker_quarantine) ++
        quarantine_for_malformed("registry_validation_resources", validation_quarantine)

    journal_quarantine = journal_quarantine(state)

    all_resources =
      Enum.concat([
        live,
        retained,
        blockers,
        validation,
        malformed_quarantine,
        journal_quarantine
      ])

    matching_resources = Enum.filter(all_resources, &matches_filters?(&1, task_id, principal_id))
    sorted_resources = Enum.sort_by(matching_resources, &sort_key/1)
    resources = Enum.take(sorted_resources, max_items)

    available_count = bounded_count(length(all_resources))
    matching_count = bounded_count(length(matching_resources))
    returned_count = length(resources)
    truncated_count = max(matching_count - returned_count, 0)

    %{
      "schema_version" => @schema_version,
      "journal" => journal_status(state),
      "filters" => %{"task_id" => task_id, "principal_id" => principal_id},
      "max_items" => max_items,
      "truncated" => truncated_count > 0,
      "counts" => %{
        "available" => available_count,
        "matching" => matching_count,
        "returned" => returned_count,
        "filtered_out" => max(available_count - matching_count, 0),
        "truncated" => truncated_count,
        "by_type" => counts_by_type(matching_resources)
      },
      "resources" => resources
    }
  end

  defp project_collection(state, state_key, kind) do
    state
    |> records(state_key)
    |> Enum.reduce({[], 0}, fn record, {resources, quarantine_count} ->
      case project_record(record, kind) do
        {:ok, resource} -> {[resource | resources], quarantine_count}
        :quarantine -> {resources, quarantine_count + 1}
      end
    end)
    |> then(fn {resources, quarantine_count} -> {Enum.reverse(resources), quarantine_count} end)
  end

  defp project_validation_collection(state, workspace_join) do
    state
    |> records(:validation_resources)
    |> Enum.reduce({[], 0}, fn record, {resources, quarantine_count} ->
      case project_validation(record, workspace_join, state) do
        {:ok, resource} -> {[resource | resources], quarantine_count}
        :quarantine -> {resources, quarantine_count + 1}
      end
    end)
    |> then(fn {resources, quarantine_count} -> {Enum.reverse(resources), quarantine_count} end)
  end

  defp records(state, key) do
    case Map.get(state, key) do
      values when is_map(values) -> Map.values(values)
      _ -> []
    end
  end

  defp project_record(record, :live) when is_map(record) do
    with {:ok, workspace_id} <- required_string(record, :workspace_id, @max_id_bytes),
         {:ok, repo_path} <- required_string(record, :repo_path, @max_path_bytes),
         {:ok, worktree_path} <- required_string(record, :worktree_path, @max_path_bytes),
         {:ok, branch} <- required_string(record, :branch, @max_branch_bytes),
         {:ok, base_commit} <- required_string(record, :base_commit, @max_commit_bytes),
         {:ok, ownership} <- closed_ownership(Map.get(record, :ownership)),
         {:ok, provenance} <- closed_provenance(Map.get(record, :branch_provenance)) do
      {:ok,
       %{
         "resource_type" => @resource_types.live,
         "resource_id" => workspace_id,
         "workspace_id" => workspace_id,
         "task_id" => optional_string(record, :task_id, @max_id_bytes),
         "principal_id" => optional_string(record, :principal_id, @max_id_bytes),
         "repo_path" => repo_path,
         "worktree_path" => worktree_path,
         "branch" => branch,
         "base_commit" => base_commit,
         "ownership" => ownership,
         "branch_provenance" => provenance,
         "lifecycle" => "active",
         "active" => Map.get(record, :active) == true,
         "cleanup_armed" => Map.get(record, :cleanup_armed) == true,
         "retry_state" => retry_state(record, :owner_death_retry_count, :owner_death_retry_limit),
         "expires_at" =>
           iso_datetime(Map.get(record, :retention_expires_at) || Map.get(record, :expires_at))
       }}
    else
      _ -> :quarantine
    end
  end

  defp project_record(record, :retained) when is_map(record) do
    with {:ok, workspace_id} <- required_string(record, :workspace_id, @max_id_bytes),
         {:ok, repo_path} <- required_string(record, :repo_path, @max_path_bytes),
         {:ok, worktree_path} <- required_string(record, :worktree_path, @max_path_bytes),
         {:ok, branch} <- required_string(record, :branch, @max_branch_bytes),
         {:ok, lifecycle} <- closed_lifecycle(Map.get(record, :lifecycle)),
         {:ok, ownership} <- closed_ownership(Map.get(record, :ownership)),
         {:ok, provenance} <- closed_provenance(Map.get(record, :branch_provenance)) do
      {:ok,
       %{
         "resource_type" => @resource_types.retained,
         "resource_id" => workspace_id,
         "workspace_id" => workspace_id,
         "task_id" => optional_string(record, :task_id, @max_id_bytes),
         "principal_id" => optional_string(record, :principal_id, @max_id_bytes),
         "repo_path" => repo_path,
         "worktree_path" => worktree_path,
         "branch" => branch,
         "base_commit" => optional_string(record, :base_commit, @max_commit_bytes),
         "settlement_tip" => optional_string(record, :settlement_tip, @max_commit_bytes),
         "ownership" => ownership,
         "branch_provenance" => provenance,
         "lifecycle" => lifecycle,
         "active" => false,
         "cleanup_armed" => not (Map.get(record, :dormant) == true),
         "dormant" => Map.get(record, :dormant) == true,
         "discard_phase" => closed_phase(Map.get(record, :discard_phase)),
         "retry_state" => retry_state(record, :retry_count, :retained_cleanup_retry_limit),
         "expires_at" => iso_datetime(Map.get(record, :expires_at))
       }}
    else
      _ -> :quarantine
    end
  end

  defp project_record(_record, _kind), do: :quarantine

  defp project_validation(record, workspace_join, state) when is_map(record) do
    workspace_id = optional_string(record, :workspace_id, @max_id_bytes)
    parent = Map.get(workspace_join, workspace_id, %{})

    with {:ok, resource_id} <- required_string(record, :resource_id, @max_id_bytes),
         {:ok, workspace_id} <- required_string(record, :workspace_id, @max_id_bytes),
         {:ok, repo_path} <- required_string(record, :repo_path, @max_path_bytes),
         {:ok, candidate_path} <- required_string(record, :candidate_path, @max_path_bytes),
         {:ok, setup_status} <- validation_setup_status(Map.get(record, :setup_status)) do
      {:ok,
       %{
         "resource_type" => @resource_types.validation,
         "resource_id" => resource_id,
         "workspace_id" => workspace_id,
         "task_id" => Map.get(parent, "task_id"),
         "principal_id" => Map.get(parent, "principal_id"),
         "repo_path" => repo_path,
         "worktree_path" => Map.get(parent, "worktree_path"),
         "candidate_path" => candidate_path,
         "candidate_commit" => optional_string(record, :candidate_commit, @max_commit_bytes),
         "base_commit" =>
           optional_string(record, :base_commit, @max_commit_bytes) ||
             Map.get(parent, "base_commit"),
         "base_worktree_path" => optional_string(record, :base_worktree_path, @max_path_bytes),
         "branch" => Map.get(parent, "branch"),
         "branch_provenance" => Map.get(parent, "branch_provenance"),
         "ownership" => "owned",
         "lifecycle" => setup_status,
         "active" => true,
         "cleanup_armed" => false,
         "cleanup_state" => validation_cleanup_state(record),
         "retry_state" => %{
           "count" => bounded_retry(Map.get(record, :resource_owner_cleanup_retry_count)),
           "limit" => bounded_limit(Map.get(state, :validation_owner_cleanup_retry_limit)),
           "dormant" => Map.get(record, :resource_owner_cleanup_dormant) == true
         },
         "expires_at" => nil
       }}
    else
      _ -> :quarantine
    end
  end

  defp project_validation(_record, _workspace_join, _state), do: :quarantine

  defp join_index(resources) do
    Enum.reduce(resources, %{}, fn resource, acc ->
      case Map.get(resource, "workspace_id") do
        workspace_id when is_binary(workspace_id) -> Map.put(acc, workspace_id, resource)
        _ -> acc
      end
    end)
  end

  defp quarantine_for_malformed(_source, 0), do: []

  defp quarantine_for_malformed(source, count) do
    [quarantine_entry("malformed:" <> source, source, "malformed_record", count)]
  end

  defp journal_quarantine(state) do
    journal = Map.get(state, :retention_journal, %{})

    if is_map(journal) and Map.get(journal, :status) in [:poisoned, "poisoned"] do
      [
        quarantine_entry(
          "journal:workspace_retention",
          "workspace_retention_journal",
          "poisoned_journal",
          1
        )
      ]
    else
      []
    end
  end

  defp quarantine_entry(resource_id, source, reason, count) do
    %{
      "resource_type" => @resource_types.quarantine,
      "resource_id" => resource_id,
      "workspace_id" => nil,
      "task_id" => nil,
      "principal_id" => nil,
      "source" => source,
      "quarantine_reason" => reason,
      "evidence_count" => bounded_count(count),
      "active" => false
    }
  end

  defp journal_status(state) do
    journal = Map.get(state, :retention_journal, %{})
    status = if is_map(journal), do: Map.get(journal, :status), else: :poisoned
    reason? = is_map(journal) and not is_nil(Map.get(journal, :reason))

    status_string =
      cond do
        status in [:ready, "ready"] and not reason? -> "complete"
        status in [:disabled, "disabled"] and not reason? -> "disabled"
        true -> "degraded"
      end

    result = %{"status" => status_string, "quarantined" => status_string == "degraded"}

    if status_string == "degraded" do
      Map.put(result, "failure_category", "retention_journal_poisoned")
    else
      result
    end
  end

  defp matches_filters?(
         %{"resource_type" => "quarantine"},
         _task_id,
         _principal_id
       ),
       do: true

  defp matches_filters?(resource, task_id, principal_id) do
    (is_nil(task_id) or Map.get(resource, "task_id") == task_id) and
      (is_nil(principal_id) or Map.get(resource, "principal_id") == principal_id)
  end

  defp sort_key(resource) do
    type = Map.get(resource, "resource_type", @resource_types.quarantine)
    {Map.get(@type_order, type, 99), type, Map.get(resource, "resource_id", "")}
  end

  defp counts_by_type(resources) do
    @resource_types
    |> Map.values()
    |> Enum.sort_by(&Map.get(@type_order, &1, 99))
    |> Map.new(fn type ->
      {type, bounded_count(Enum.count(resources, &(Map.get(&1, "resource_type") == type)))}
    end)
  end

  defp retry_state(record, count_key, limit_key) do
    %{
      "count" => bounded_retry(Map.get(record, count_key)),
      "limit" => bounded_limit(Map.get(record, limit_key)),
      "dormant" => Map.get(record, :dormant) == true
    }
  end

  defp validation_cleanup_state(record) do
    cond do
      Map.get(record, :resource_owner_cleanup_dormant) == true -> "dormant"
      is_pid(Map.get(record, :resource_owner_pid)) -> "owned"
      true -> "retrying"
    end
  end

  defp validation_setup_status(:active), do: {:ok, "active"}
  defp validation_setup_status("active"), do: {:ok, "active"}
  defp validation_setup_status(:setup_failed), do: {:ok, "setup_failed"}
  defp validation_setup_status("setup_failed"), do: {:ok, "setup_failed"}
  defp validation_setup_status(_status), do: {:error, :invalid_validation_setup_status}

  defp closed_ownership(:owned), do: {:ok, "owned"}
  defp closed_ownership("owned"), do: {:ok, "owned"}
  defp closed_ownership(:reused), do: {:ok, "reused"}
  defp closed_ownership("reused"), do: {:ok, "reused"}
  defp closed_ownership(:pending), do: {:ok, "pending"}
  defp closed_ownership("pending"), do: {:ok, "pending"}
  defp closed_ownership(_ownership), do: {:error, :invalid_ownership}

  defp closed_provenance(:created), do: {:ok, "created"}
  defp closed_provenance("created"), do: {:ok, "created"}
  defp closed_provenance(:reused), do: {:ok, "reused"}
  defp closed_provenance("reused"), do: {:ok, "reused"}
  defp closed_provenance(:unknown), do: {:ok, "unknown"}
  defp closed_provenance("unknown"), do: {:ok, "unknown"}
  defp closed_provenance(nil), do: {:ok, "unknown"}
  defp closed_provenance(_provenance), do: {:error, :invalid_branch_provenance}

  defp closed_lifecycle(:retained), do: {:ok, "retained"}
  defp closed_lifecycle("retained"), do: {:ok, "retained"}
  defp closed_lifecycle(:active_orphaned), do: {:ok, "active_orphaned"}
  defp closed_lifecycle("active_orphaned"), do: {:ok, "active_orphaned"}
  defp closed_lifecycle(:discarding), do: {:ok, "discarding"}
  defp closed_lifecycle("discarding"), do: {:ok, "discarding"}
  defp closed_lifecycle(:creating), do: {:ok, "creating"}
  defp closed_lifecycle("creating"), do: {:ok, "creating"}
  defp closed_lifecycle(_lifecycle), do: {:error, :invalid_lifecycle}

  defp closed_phase(nil), do: nil
  defp closed_phase(phase) when phase in [:archive, :worktree, :branch], do: Atom.to_string(phase)
  defp closed_phase(phase) when phase in ["archive", "worktree", "branch"], do: phase
  defp closed_phase(_phase), do: nil

  defp required_string(record, key, max_bytes) do
    case Map.get(record, key) do
      value when is_binary(value) and byte_size(value) <= max_bytes ->
        if String.valid?(value) and value != "" and not String.contains?(value, <<0>>),
          do: {:ok, value},
          else: {:error, :invalid_string}

      _ ->
        {:error, :invalid_string}
    end
  end

  defp optional_string(record, key, max_bytes) do
    case Map.get(record, key) do
      nil ->
        nil

      value when is_binary(value) and byte_size(value) <= max_bytes ->
        if not String.valid?(value) or value == "" or String.contains?(value, <<0>>),
          do: nil,
          else: value

      _ ->
        nil
    end
  end

  defp iso_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp iso_datetime(value) when is_binary(value) and byte_size(value) <= 64 do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> value
      _ -> nil
    end
  end

  defp iso_datetime(_value), do: nil

  defp bounded_retry(value) when is_integer(value) and value >= 0,
    do: min(value, @max_retry_count)

  defp bounded_retry(_value), do: 0

  defp bounded_limit(value) when is_integer(value) and value >= 0,
    do: min(value, @max_retry_count)

  defp bounded_limit(_value), do: 0

  defp bounded_count(value) when is_integer(value) and value >= 0, do: min(value, @max_count)
  defp bounded_count(_value), do: 0
end
