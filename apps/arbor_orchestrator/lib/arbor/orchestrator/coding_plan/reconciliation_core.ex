defmodule Arbor.Orchestrator.CodingPlan.ReconciliationCore do
  @moduledoc """
  Pure first-slice reconciliation of coding resources against task observations.

  The inputs are the JSON-clean public task and coding-resource projections.
  This module does not interpret paths, PIDs, process terms, authorities, or
  arbitrary metadata. It emits evidence only; an imperative shell can later
  decide whether a validated manifest is still current before applying it.
  """

  alias Arbor.Contracts.Coding.ReconciliationManifest

  @schema_version 1
  @max_tasks 1_000
  @max_resources 1_000
  @max_json_bytes 1_000_000
  # Match the producer collection bounds; the document byte limit remains
  # the independent protection against large records.
  @max_json_collection_items 1_000
  @resource_types ~w(live_workspace_lease retained_workspace_record validation_resource quarantine)
  @resource_order %{
    "live_workspace_lease" => 0,
    "retained_workspace_record" => 1,
    "validation_resource" => 2,
    "quarantine" => 3
  }
  @task_states ~w(running waiting_approval done failed cancelled)
  @terminal_states ~w(done failed cancelled)
  @live_states ~w(running waiting_approval)
  @source_task_fields ~w(
    task_id agent_id state current_step waiting_on started_at updated_at completed_at
    owner_process control_counts evidence_present artifacts_present outcome
  )
  @source_resource_fields ~w(
    resource_type resource_id workspace_id task_id principal_id repo_path worktree_path branch
    base_commit settlement_tip candidate_path candidate_commit base_worktree_path ownership
    branch_provenance lifecycle active cleanup_armed dormant retry_state expires_at discard_phase
    cleanup_state source quarantine_reason evidence_count
  )
  @scope_fields ~w(task_id principal_id agent_id state)

  @type state :: %{
          required(:observed_at) => String.t(),
          required(:scope) => map(),
          required(:task_inventory) => map(),
          required(:resource_inventory) => map(),
          required(:observation_digest) => map()
        }

  @doc "Construct normalized reconciliation state from bounded JSON observations."
  @spec new(map() | keyword()) :: {:ok, state()} | {:error, term()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    with {:ok, attrs} <-
           normalize_object(attrs, ~w(task_inventory resource_inventory observed_at scope)),
         {:ok, task_inventory} <- normalize_task_inventory(fetch(attrs, "task_inventory")),
         {:ok, resource_inventory} <-
           normalize_resource_inventory(fetch(attrs, "resource_inventory")),
         :ok <-
           validate_scope_consistency(task_inventory["filters"], resource_inventory["filters"]),
         :ok <- no_truncation(task_inventory, resource_inventory),
         {:ok, observed_at} <- normalize_observed_at(fetch(attrs, "observed_at")),
         {:ok, scope} <-
           normalize_scope(fetch(attrs, "scope"), task_inventory, resource_inventory),
         {:ok, observation_digest} <- observation_digest(task_inventory, resource_inventory),
         :ok <-
           bounded_document?(%{
             "task_inventory" => task_inventory,
             "resource_inventory" => resource_inventory
           }) do
      {:ok,
       %{
         observed_at: observed_at,
         scope: scope,
         task_inventory: task_inventory,
         resource_inventory: resource_inventory,
         observation_digest: observation_digest
       }}
    end
  rescue
    _ -> {:error, :malformed_observation}
  catch
    _, _ -> {:error, :malformed_observation}
  end

  def new(_attrs), do: {:error, :malformed_observation}

  @doc "Reduce normalized observations to decisions and bounded counts."
  @spec reduce(state()) :: {:ok, map()} | {:error, term()}
  def reduce(%{
        observed_at: observed_at,
        scope: scope,
        task_inventory: task_inventory,
        resource_inventory: resource_inventory,
        observation_digest: observation_digest
      }) do
    task_index = Map.new(task_inventory["tasks"], &{&1["task_id"], &1})
    journal_status = resource_inventory["journal"]["status"]

    decisions =
      resource_inventory["resources"]
      |> Enum.map(&decide(&1, task_index, journal_status, observed_at))
      |> Enum.sort_by(&decision_sort_key/1)

    {:ok,
     %{
       "schema_version" => @schema_version,
       "observed_at" => observed_at,
       "scope" => scope,
       "observation_digest" => observation_digest,
       "decisions" => decisions,
       "counts" => counts(decisions)
     }}
  rescue
    _ -> {:error, :malformed_observation}
  catch
    _, _ -> {:error, :malformed_observation}
  end

  def reduce(_state), do: {:error, :malformed_observation}

  @doc "Convert reduced state to the validated canonical manifest map."
  @spec show(map()) :: {:ok, map()} | {:error, term()}
  def show(reduced) when is_map(reduced) do
    with {:ok, manifest} <- ReconciliationManifest.new(reduced) do
      {:ok, ReconciliationManifest.to_map(manifest)}
    end
  rescue
    _ -> {:error, :malformed_manifest}
  catch
    _, _ -> {:error, :malformed_manifest}
  end

  def show(_reduced), do: {:error, :malformed_manifest}

  @doc "Reconcile observations and return `{manifest, manifest_sha256}`."
  @spec reconcile(map() | keyword(), map() | keyword(), term(), map() | keyword()) ::
          {:ok, map(), String.t()} | {:error, term()}
  def reconcile(task_inventory, resource_inventory, observed_at, scope \\ %{}) do
    attrs = %{
      "task_inventory" => task_inventory,
      "resource_inventory" => resource_inventory,
      "observed_at" => observed_at,
      "scope" => scope
    }

    with {:ok, state} <- new(attrs),
         {:ok, reduced} <- reduce(state),
         {:ok, manifest} <- show(reduced),
         {:ok, digest} <- ReconciliationManifest.digest(manifest) do
      {:ok, manifest, digest}
    end
  rescue
    _ -> {:error, :malformed_observation}
  catch
    _, _ -> {:error, :malformed_observation}
  end

  defp normalize_task_inventory(inventory) when is_map(inventory) and not is_struct(inventory) do
    with {:ok, inventory} <-
           object(inventory, ~w(schema_version storage filters max_items truncated counts tasks)),
         :ok <-
           exact(inventory, ~w(schema_version storage filters max_items truncated counts tasks)),
         :ok <- version(inventory["schema_version"]),
         :ok <- exact(inventory["storage"], ~w(durability)),
         :ok <- value(inventory["storage"]["durability"], "volatile"),
         :ok <- exact(inventory["filters"], ~w(task_id agent_id state)),
         :ok <- optional_id(inventory["filters"]["task_id"]),
         :ok <- optional_id(inventory["filters"]["agent_id"]),
         :ok <- optional_enum(inventory["filters"]["state"], @task_states),
         :ok <- positive_count(inventory["max_items"], @max_tasks),
         :ok <- boolean_value(inventory["truncated"]),
         {:ok, counts} <- normalize_task_counts(inventory["counts"]),
         {:ok, tasks} <- normalize_tasks(inventory["tasks"], counts["returned"]),
         :ok <- validate_task_count_invariants(counts, length(tasks)) do
      {:ok, Map.put(inventory, "tasks", tasks)}
    end
  end

  defp normalize_task_inventory(_inventory), do: {:error, :malformed_task_inventory}

  defp normalize_resource_inventory(inventory)
       when is_map(inventory) and not is_struct(inventory) do
    with {:ok, inventory} <-
           object(
             inventory,
             ~w(schema_version journal filters max_items truncated counts resources)
           ),
         :ok <-
           exact(
             inventory,
             ~w(schema_version journal filters max_items truncated counts resources)
           ),
         :ok <- version(inventory["schema_version"]),
         {:ok, journal} <- normalize_journal(inventory["journal"]),
         {:ok, filters} <- normalize_resource_filters(inventory["filters"]),
         :ok <- positive_count(inventory["max_items"], @max_resources),
         :ok <- boolean_value(inventory["truncated"]),
         {:ok, counts} <- normalize_resource_counts(inventory["counts"]),
         {:ok, resources} <- normalize_resources(inventory["resources"], counts["returned"]),
         :ok <- validate_resource_count_invariants(counts, resources) do
      {:ok, %{inventory | "journal" => journal, "filters" => filters, "resources" => resources}}
    end
  end

  defp normalize_resource_inventory(_inventory), do: {:error, :malformed_resource_inventory}

  defp normalize_task_counts(counts) when is_map(counts) do
    with {:ok, counts} <-
           object(counts, ~w(observed matching returned filtered_out truncated malformed)),
         :ok <- exact(counts, ~w(observed matching returned filtered_out truncated malformed)),
         :ok <- count_at_most(counts["observed"], @max_tasks),
         :ok <- count_at_most(counts["matching"], @max_tasks),
         :ok <- count_at_most(counts["returned"], @max_tasks),
         :ok <- count_at_most(counts["filtered_out"], @max_tasks),
         :ok <- count_at_most(counts["truncated"], @max_tasks),
         :ok <- count_at_most(counts["malformed"], @max_tasks) do
      {:ok, counts}
    end
  end

  defp normalize_task_counts(_counts), do: {:error, :malformed_task_counts}

  defp validate_task_count_invariants(counts, returned) do
    if counts["returned"] == returned and
         counts["observed"] ==
           counts["malformed"] + counts["filtered_out"] + counts["matching"] and
         counts["matching"] == counts["returned"] + counts["truncated"],
       do: :ok,
       else: {:error, :inconsistent_task_counts}
  end

  defp normalize_resource_counts(counts) when is_map(counts) do
    with {:ok, counts} <-
           object(counts, ~w(available matching returned filtered_out truncated by_type)),
         :ok <- exact(counts, ~w(available matching returned filtered_out truncated by_type)),
         :ok <- count_at_most(counts["available"], @max_resources),
         :ok <- count_at_most(counts["matching"], @max_resources),
         :ok <- count_at_most(counts["returned"], @max_resources),
         :ok <- count_at_most(counts["filtered_out"], @max_resources),
         :ok <- count_at_most(counts["truncated"], @max_resources),
         :ok <- normalize_by_type(counts["by_type"]) do
      {:ok, counts}
    end
  end

  defp normalize_resource_counts(_counts), do: {:error, :malformed_resource_counts}

  defp validate_resource_count_invariants(counts, resources) do
    by_type_total = Enum.sum(Map.values(counts["by_type"]))
    returned_by_type = Enum.frequencies_by(resources, & &1["resource_type"])

    by_type_matches_returned? =
      counts["truncated"] > 0 or
        Enum.all?(@resource_types, fn type ->
          Map.get(counts["by_type"], type, 0) == Map.get(returned_by_type, type, 0)
        end)

    if counts["available"] == counts["filtered_out"] + counts["matching"] and
         counts["matching"] == counts["returned"] + counts["truncated"] and
         by_type_total == counts["matching"] and by_type_matches_returned?,
       do: :ok,
       else: {:error, :inconsistent_resource_counts}
  end

  defp normalize_by_type(value) when is_map(value) do
    with {:ok, value} <- object(value, @resource_types),
         :ok <- exact(value, @resource_types) do
      Enum.reduce_while(@resource_types, :ok, fn type, :ok ->
        case count_at_most(value[type], @max_resources) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp normalize_by_type(_value), do: {:error, :malformed_by_type}

  defp normalize_tasks(tasks, returned) when is_list(tasks) do
    if length(tasks) <= @max_tasks and length(tasks) == returned do
      with {:ok, normalized} <- normalize_task_entries(tasks),
           :ok <- reject_duplicate_ids(normalized, "task_id") do
        {:ok, Enum.sort_by(normalized, & &1["task_id"])}
      end
    else
      {:error, :malformed_tasks}
    end
  end

  defp normalize_tasks(_tasks, _returned), do: {:error, :malformed_tasks}

  defp normalize_task_entries(tasks) do
    Enum.reduce_while(tasks, {:ok, []}, fn task, {:ok, acc} ->
      case normalize_task(task) do
        {:ok, task} -> {:cont, {:ok, [task | acc]}}
        error -> {:halt, error}
      end
    end)
    |> reverse_ok()
  end

  defp normalize_task(task) when is_map(task) and not is_struct(task) do
    with {:ok, task} <- object(task, @source_task_fields),
         :ok <-
           required_exact(
             task,
             ~w(task_id agent_id state current_step waiting_on started_at updated_at completed_at owner_process control_counts evidence_present artifacts_present)
           ),
         {:ok, task_id} <- required_id(task["task_id"]),
         :ok <- required_id_value(task["agent_id"]),
         :ok <- enum_value(task["state"], @task_states),
         :ok <- optional_text_value(task["current_step"]),
         :ok <- optional_text_value(task["waiting_on"]),
         :ok <- timestamp_value(task["started_at"]),
         :ok <- timestamp_value(task["updated_at"]),
         :ok <- optional_timestamp_value(task["completed_at"]),
         :ok <- normalize_owner(task["owner_process"]),
         :ok <- normalize_control_counts(task["control_counts"]),
         :ok <- boolean_value(task["evidence_present"]),
         :ok <- boolean_value(task["artifacts_present"]),
         :ok <- optional_json(task["outcome"]) do
      {:ok, Map.put(task, "task_id", task_id)}
    end
  end

  defp normalize_task(_task), do: {:error, :malformed_task}

  defp normalize_owner(owner) when is_map(owner) do
    with {:ok, owner} <- object(owner, ~w(present alive)),
         :ok <- exact(owner, ~w(present alive)),
         :ok <- boolean_value(owner["present"]),
         :ok <- boolean_value(owner["alive"]) do
      if owner["alive"] and not owner["present"], do: {:error, :ambiguous_owner}, else: :ok
    end
  end

  defp normalize_owner(_owner), do: {:error, :malformed_owner}

  defp normalize_control_counts(counts) when is_map(counts) do
    with {:ok, counts} <- object(counts, ~w(closed open)),
         :ok <- exact(counts, ~w(closed open)),
         :ok <- count_at_most(counts["closed"], 100_000),
         :ok <- count_at_most(counts["open"], 100_000) do
      :ok
    end
  end

  defp normalize_control_counts(_counts), do: {:error, :malformed_control_counts}

  defp normalize_journal(journal) when is_map(journal) do
    with {:ok, journal} <- object(journal, ~w(status quarantined failure_category)),
         :ok <- required_exact(journal, ~w(status quarantined)),
         :ok <- enum_value(journal["status"], ~w(complete disabled degraded)),
         :ok <- boolean_value(journal["quarantined"]),
         :ok <- optional_text_value(journal["failure_category"]),
         :ok <- validate_journal_consistency(journal) do
      {:ok, journal}
    end
  end

  defp normalize_journal(_journal), do: {:error, :malformed_journal}

  defp validate_journal_consistency(%{"status" => "degraded", "quarantined" => true} = journal) do
    if is_binary(journal["failure_category"]) and journal["failure_category"] != "",
      do: :ok,
      else: {:error, :inconsistent_journal}
  end

  defp validate_journal_consistency(%{"status" => status, "quarantined" => false} = journal)
       when status in ["complete", "disabled"] do
    if not Map.has_key?(journal, "failure_category") or is_nil(journal["failure_category"]),
      do: :ok,
      else: {:error, :inconsistent_journal}
  end

  defp validate_journal_consistency(_journal), do: {:error, :inconsistent_journal}

  defp normalize_resource_filters(filters) when is_map(filters) do
    with {:ok, filters} <- object(filters, ~w(task_id principal_id)),
         :ok <- exact(filters, ~w(task_id principal_id)),
         :ok <- optional_id(filters["task_id"]),
         :ok <- optional_id(filters["principal_id"]) do
      {:ok, filters}
    end
  end

  defp normalize_resource_filters(_filters), do: {:error, :malformed_resource_filters}

  defp normalize_resources(resources, returned) when is_list(resources) do
    if length(resources) <= @max_resources and length(resources) == returned do
      with {:ok, normalized} <- normalize_resource_entries(resources),
           :ok <- reject_duplicate_identities(normalized) do
        {:ok, Enum.sort_by(normalized, &resource_sort_key/1)}
      end
    else
      {:error, :malformed_resources}
    end
  end

  defp normalize_resources(_resources, _returned), do: {:error, :malformed_resources}

  defp normalize_resource_entries(resources) do
    Enum.reduce_while(resources, {:ok, []}, fn resource, {:ok, acc} ->
      case normalize_resource(resource) do
        {:ok, resource} ->
          {:cont, {:ok, [resource | acc]}}

        error ->
          {:halt, error}
      end
    end)
    |> reverse_ok()
  end

  defp normalize_resource(resource) when is_map(resource) and not is_struct(resource) do
    with {:ok, resource} <- object(resource, @source_resource_fields),
         {:ok, resource_type} <- enum_value_result(resource["resource_type"], @resource_types),
         {:ok, resource_id} <- required_id(resource["resource_id"]),
         :ok <- optional_id(resource["workspace_id"]),
         :ok <- optional_id(resource["task_id"]),
         :ok <- optional_id(resource["principal_id"]),
         :ok <- optional_fields(resource),
         :ok <- boolean_value(resource["active"]) do
      {:ok,
       resource |> Map.put("resource_type", resource_type) |> Map.put("resource_id", resource_id)}
    end
  end

  defp normalize_resource(_resource), do: {:error, :malformed_resource}

  defp optional_fields(resource) do
    with :ok <- optional_text_value(resource["repo_path"]),
         :ok <- optional_text_value(resource["worktree_path"]),
         :ok <- optional_text_value(resource["branch"]),
         :ok <- optional_text_value(resource["base_commit"]),
         :ok <- optional_text_value(resource["settlement_tip"]),
         :ok <- optional_text_value(resource["candidate_path"]),
         :ok <- optional_text_value(resource["candidate_commit"]),
         :ok <- optional_text_value(resource["base_worktree_path"]),
         :ok <- optional_enum_value(resource["ownership"], ~w(owned reused pending)),
         :ok <- optional_enum_value(resource["branch_provenance"], ~w(created reused unknown)),
         :ok <-
           optional_enum_value(
             resource["lifecycle"],
             ~w(active retained active_orphaned discarding creating setup_failed)
           ),
         :ok <- optional_boolean_value(resource["cleanup_armed"]),
         :ok <- optional_boolean_value(resource["dormant"]),
         :ok <- optional_timestamp_value(resource["expires_at"]),
         :ok <- optional_enum_value(resource["discard_phase"], ~w(archive worktree branch)),
         :ok <- optional_enum_value(resource["cleanup_state"], ~w(dormant owned retrying)),
         :ok <- optional_text_value(resource["source"]),
         :ok <- optional_text_value(resource["quarantine_reason"]),
         :ok <- optional_count(resource["evidence_count"]),
         :ok <- normalize_retry_state(resource["retry_state"]) do
      :ok
    end
  end

  defp normalize_retry_state(nil), do: :ok

  defp normalize_retry_state(value) when is_map(value) do
    with {:ok, value} <- object(value, ~w(count limit dormant)),
         :ok <- required_exact(value, ~w(count limit dormant)),
         :ok <- count_at_most(value["count"], 1_000_000),
         :ok <- count_at_most(value["limit"], 1_000_000),
         :ok <- boolean_value(value["dormant"]) do
      :ok
    end
  end

  defp normalize_retry_state(_value), do: {:error, :malformed_retry_state}

  defp decide(resource, task_index, journal_status, observed_at) do
    type = resource["resource_type"]
    task_id = resource["task_id"]
    principal_id = resource["principal_id"]
    task = Map.get(task_index, task_id)
    owner_status = owner_status(task)
    task_state = if is_map(task), do: task["state"], else: nil

    {decision, reason} =
      cond do
        type == "quarantine" ->
          {"quarantine", "existing_quarantine"}

        journal_status == "degraded" ->
          {"quarantine", "journal_degraded"}

        is_nil(task_id) or is_nil(principal_id) ->
          {"quarantine", "missing_task_or_principal_provenance"}

        resource["ownership"] == "pending" or resource["branch_provenance"] in [nil, "unknown"] ->
          {"quarantine", "ambiguous_provenance"}

        retry_dormant?(resource) ->
          {"quarantine", "dormant_resource"}

        retry_exhausted?(resource) ->
          {"quarantine", "retry_exhausted"}

        is_nil(task) ->
          {"quarantine", "missing_task"}

        task_state in @live_states and owner_status == "live" ->
          {"keep", "live_task_owner_alive"}

        task_state in @live_states ->
          {"retry", "live_task_owner_dead"}

        type in ["live_workspace_lease", "validation_resource"] and task_state in @terminal_states ->
          {"settle", "terminal_active_resource"}

        type == "retained_workspace_record" and task_state in @terminal_states ->
          retained_decision(resource, observed_at)

        true ->
          {"quarantine", "ambiguous_provenance"}
      end

    %{
      "schema_version" => @schema_version,
      "resource_type" => type,
      "resource_id" => resource["resource_id"],
      "task_id" => task_id,
      "principal_id" => principal_id,
      "decision" => decision,
      "reason" => reason,
      "expected_identity" => expected_identity(resource),
      "evidence" => %{
        "task_presence" => if(is_map(task), do: "observed", else: "absent"),
        "task_state" => task_state,
        "owner_status" => owner_status,
        "journal_status" => journal_status
      }
    }
  end

  defp retained_decision(resource, observed_at) do
    case resource["expires_at"] do
      nil ->
        {"quarantine", "ambiguous_provenance"}

      expires_at ->
        case DateTime.compare(parse_datetime!(expires_at), parse_datetime!(observed_at)) do
          :gt -> {"keep", "retained_within_retention"}
          _ -> {"settle", "retained_expired"}
        end
    end
  end

  defp expected_identity(resource) do
    retry_state = resource["retry_state"] || %{}

    %{
      "resource_type" => resource["resource_type"],
      "resource_id" => resource["resource_id"],
      "task_id" => resource["task_id"],
      "principal_id" => resource["principal_id"],
      "lifecycle" => resource["lifecycle"],
      "active" => resource["active"],
      "ownership" => resource["ownership"],
      "branch_provenance" => resource["branch_provenance"],
      "cleanup_armed" => resource["cleanup_armed"] || false,
      "dormant" => resource["dormant"] || retry_state["dormant"] || false,
      "retry_count" => retry_state["count"] || 0,
      "retry_limit" => retry_state["limit"] || 0,
      "expires_at" => resource["expires_at"]
    }
  end

  defp owner_status(nil), do: "absent"

  defp owner_status(task) do
    owner = task["owner_process"]
    if owner["present"] and owner["alive"], do: "live", else: "dead"
  end

  defp retry_dormant?(resource) do
    resource["dormant"] == true or get_in(resource, ["retry_state", "dormant"]) == true
  end

  defp retry_exhausted?(resource) do
    case resource["retry_state"] do
      %{"count" => count, "limit" => limit} when limit > 0 -> count >= limit
      _ -> false
    end
  end

  defp counts(decisions) do
    frequencies = Enum.frequencies_by(decisions, & &1["decision"])

    %{
      "resources" => length(decisions),
      "keep" => Map.get(frequencies, "keep", 0),
      "retry" => Map.get(frequencies, "retry", 0),
      "settle" => Map.get(frequencies, "settle", 0),
      "quarantine" => Map.get(frequencies, "quarantine", 0),
      "remove" => Map.get(frequencies, "remove", 0)
    }
  end

  defp decision_sort_key(decision) do
    {Map.get(@resource_order, decision["resource_type"], 99), decision["resource_type"],
     decision["resource_id"], decision["task_id"] || "", decision["principal_id"] || ""}
  end

  defp resource_sort_key(resource) do
    {Map.get(@resource_order, resource["resource_type"], 99), resource["resource_type"],
     resource["resource_id"]}
  end

  defp observation_digest(tasks, resources) do
    task_digest = sha256(canonical_json(tasks))
    resource_digest = sha256(canonical_json(resources))
    source = %{"task_inventory" => tasks, "resource_inventory" => resources}

    {:ok,
     %{
       "task_inventory_sha256" => task_digest,
       "resource_inventory_sha256" => resource_digest,
       "source_sha256" => sha256(canonical_json(source))
     }}
  end

  defp normalize_scope(nil, task_inventory, resource_inventory),
    do:
      normalize_scope(
        effective_scope(task_inventory, resource_inventory),
        task_inventory,
        resource_inventory
      )

  defp normalize_scope(scope, task_inventory, resource_inventory)
       when is_map(scope) and map_size(scope) == 0,
       do: normalize_scope(nil, task_inventory, resource_inventory)

  defp normalize_scope(scope, task_inventory, resource_inventory)
       when is_list(scope) or is_map(scope) do
    with {:ok, scope} <- normalize_object(scope, @scope_fields),
         {:ok, task_id} <- optional_id_result(scope["task_id"]),
         {:ok, principal_id} <- optional_id_result(scope["principal_id"]),
         {:ok, agent_id} <- optional_id_result(scope["agent_id"]),
         {:ok, state} <- optional_enum_result(scope["state"], @task_states),
         normalized = %{
           "task_id" => task_id,
           "principal_id" => principal_id,
           "agent_id" => agent_id,
           "state" => state
         },
         :ok <-
           if(normalized == effective_scope(task_inventory, resource_inventory),
             do: :ok,
             else: {:error, :inconsistent_scope}
           ) do
      {:ok, normalized}
    end
  end

  defp normalize_scope(_scope, _task_inventory, _resource_inventory),
    do: {:error, :malformed_scope}

  defp effective_scope(task_inventory, resource_inventory) do
    task_filters = task_inventory["filters"]
    resource_filters = resource_inventory["filters"]

    %{
      "task_id" => resource_filters["task_id"] || task_filters["task_id"],
      "principal_id" => resource_filters["principal_id"],
      "agent_id" => nil,
      "state" => nil
    }
  end

  defp validate_scope_consistency(task_filters, resource_filters) do
    cond do
      not is_nil(task_filters["agent_id"]) ->
        {:error, :unsupported_task_scope}

      not is_nil(task_filters["state"]) ->
        {:error, :unsupported_task_scope}

      not is_nil(task_filters["task_id"]) and
          task_filters["task_id"] != resource_filters["task_id"] ->
        {:error, :inconsistent_scope}

      true ->
        :ok
    end
  end

  defp normalize_observed_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, DateTime.to_iso8601(DateTime.shift_zone!(datetime, "Etc/UTC"), :extended)}

      _ ->
        {:error, :invalid_observed_at}
    end
  end

  defp normalize_observed_at(%DateTime{} = value),
    do: {:ok, DateTime.to_iso8601(DateTime.shift_zone!(value, "Etc/UTC"), :extended)}

  defp normalize_observed_at(_value), do: {:error, :invalid_observed_at}

  defp no_truncation(task_inventory, resource_inventory) do
    cond do
      task_inventory["truncated"] or resource_inventory["truncated"] ->
        {:error, :truncated_observation}

      task_inventory["counts"]["truncated"] > 0 or resource_inventory["counts"]["truncated"] > 0 ->
        {:error, :truncated_observation}

      task_inventory["counts"]["malformed"] > 0 ->
        {:error, :malformed_task_inventory}

      true ->
        :ok
    end
  end

  defp object(value, allowed) when is_map(value) and not is_struct(value) do
    if map_size(value) <= length(allowed) and Enum.all?(Map.keys(value), &is_binary/1) and
         Enum.all?(Map.keys(value), fn key -> Enum.member?(allowed, key) end),
       do: {:ok, value},
       else: {:error, :closed_object}
  end

  defp object(_value, _allowed), do: {:error, :closed_object}

  defp normalize_object(attrs, allowed) when is_map(attrs) do
    entries = Map.to_list(attrs)

    if Enum.all?(entries, &match?({key, _} when is_binary(key), &1)),
      do: normalize_string_entries(entries, allowed),
      else: normalize_atom_entries(entries, allowed)
  end

  defp normalize_object(attrs, allowed) when is_list(attrs) do
    entries = Enum.take(attrs, length(allowed) + 1)

    if length(entries) > length(allowed) or not Enum.all?(entries, &match?({_, _}, &1)),
      do: {:error, :closed_object},
      else: normalize_mixed_entries(entries, allowed)
  end

  defp normalize_object(_attrs, _allowed), do: {:error, :closed_object}

  defp normalize_string_entries(entries, allowed), do: normalize_mixed_entries(entries, allowed)

  defp normalize_atom_entries(entries, allowed), do: normalize_mixed_entries(entries, allowed)

  defp normalize_mixed_entries(entries, allowed) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {key, value}, {:ok, result} ->
      canonical = if is_atom(key), do: Atom.to_string(key), else: key

      if Enum.member?(allowed, canonical) and not Map.has_key?(result, canonical),
        do: {:cont, {:ok, Map.put(result, canonical, value)}},
        else: {:halt, {:error, :closed_object}}
    end)
  end

  defp fetch(attrs, key), do: Map.get(attrs, key)

  defp exact(map, fields) when is_map(map),
    do:
      if(Map.keys(map) |> Enum.sort() == fields |> Enum.sort(),
        do: :ok,
        else: {:error, :field_set}
      )

  defp required_exact(map, fields) when is_map(map),
    do: if(Enum.all?(fields, &Map.has_key?(map, &1)), do: :ok, else: {:error, :missing_field})

  defp version(@schema_version), do: :ok
  defp version(_), do: {:error, :unsupported_schema_version}

  defp value(actual, actual), do: :ok
  defp value(_actual, _expected), do: {:error, :invalid_value}

  defp positive_count(value, max),
    do:
      if(is_integer(value) and value > 0 and value <= max,
        do: :ok,
        else: {:error, :invalid_count}
      )

  defp count_at_most(value, max),
    do:
      if(is_integer(value) and value >= 0 and value <= max,
        do: :ok,
        else: {:error, :invalid_count}
      )

  defp optional_count(nil), do: :ok
  defp optional_count(value), do: count_at_most(value, 1_000_000)
  defp boolean_value(value), do: if(is_boolean(value), do: :ok, else: {:error, :invalid_boolean})
  defp optional_boolean_value(nil), do: :ok
  defp optional_boolean_value(value), do: boolean_value(value)

  defp required_id(value),
    do:
      if(
        is_binary(value) and String.valid?(value) and byte_size(value) > 0 and
          byte_size(value) <= 256 and String.trim(value) != "" and
          not String.contains?(value, <<0>>),
        do: {:ok, value},
        else: {:error, :invalid_id}
      )

  defp required_id_value(value),
    do: if(match?({:ok, _}, required_id(value)), do: :ok, else: {:error, :invalid_id})

  defp optional_id(nil), do: :ok

  defp optional_id(value),
    do: if(match?({:ok, _}, required_id(value)), do: :ok, else: {:error, :invalid_id})

  defp optional_id_result(nil), do: {:ok, nil}
  defp optional_id_result(value), do: required_id(value)

  defp enum_value(value, allowed),
    do: if(Enum.member?(allowed, value), do: :ok, else: {:error, :invalid_enum})

  defp enum_value_result(value, allowed),
    do: if(Enum.member?(allowed, value), do: {:ok, value}, else: {:error, :invalid_enum})

  defp optional_enum(value, allowed),
    do: if(is_nil(value) or Enum.member?(allowed, value), do: :ok, else: {:error, :invalid_enum})

  defp optional_enum_value(nil, _allowed), do: :ok
  defp optional_enum_value(value, allowed), do: enum_value(value, allowed)

  defp optional_enum_result(nil, _allowed), do: {:ok, nil}
  defp optional_enum_result(value, allowed), do: enum_value_result(value, allowed)

  defp optional_text_value(nil), do: :ok

  defp optional_text_value(value) when is_binary(value) and byte_size(value) <= 4_096,
    do:
      if(String.valid?(value) and not String.contains?(value, <<0>>),
        do: :ok,
        else: {:error, :invalid_text}
      )

  defp optional_text_value(_value), do: {:error, :invalid_text}

  defp timestamp_value(value) when is_binary(value),
    do:
      if(match?({:ok, _, _}, DateTime.from_iso8601(value)),
        do: :ok,
        else: {:error, :invalid_timestamp}
      )

  defp timestamp_value(_value), do: {:error, :invalid_timestamp}
  defp optional_timestamp_value(nil), do: :ok
  defp optional_timestamp_value(value), do: timestamp_value(value)
  defp parse_datetime!(value), do: elem(DateTime.from_iso8601(value), 1)

  defp optional_json(nil), do: :ok
  defp optional_json(value), do: if(bounded_json?(value), do: :ok, else: {:error, :invalid_json})

  defp bounded_document?(value) do
    if bounded_json?(value) and byte_size(Jason.encode!(value)) <= @max_json_bytes,
      do: :ok,
      else: {:error, :oversized_observation}
  end

  defp bounded_json?(value), do: bounded_json?(value, 0)
  defp bounded_json?(_value, depth) when depth > 8, do: false

  defp bounded_json?(value, depth)
       when is_map(value) and not is_struct(value) and map_size(value) <= 64,
       do:
         Enum.all?(value, fn {key, nested} ->
           is_binary(key) and byte_size(key) <= 256 and bounded_json?(nested, depth + 1)
         end)

  defp bounded_json?(value, depth)
       when is_list(value) and length(value) <= @max_json_collection_items,
       do: Enum.all?(value, &bounded_json?(&1, depth + 1))

  defp bounded_json?(value, _depth) when is_binary(value),
    do: String.valid?(value) and byte_size(value) <= 16_384

  defp bounded_json?(value, _depth) when is_number(value) or is_boolean(value) or is_nil(value),
    do: true

  defp bounded_json?(_value, _depth), do: false

  defp reject_duplicate_ids(entries, key) do
    if length(Enum.uniq_by(entries, & &1[key])) == length(entries),
      do: :ok,
      else: {:error, {:duplicate, key}}
  end

  defp reject_duplicate_identities(entries) do
    if length(Enum.uniq_by(entries, &{&1["resource_type"], &1["resource_id"]})) == length(entries),
      do: :ok,
      else: {:error, :duplicate_resource_identity}
  end

  defp reverse_ok({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok(error), do: error

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp canonical_json(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, nested} -> [Jason.encode!(key), ":", canonical_json(nested)] end)
    |> then(&["{", Enum.intersperse(&1, ","), "}"])
  end

  defp canonical_json(value) when is_list(value),
    do: ["[", Enum.intersperse(Enum.map(value, &canonical_json/1), ","), "]"]

  defp canonical_json(value), do: Jason.encode!(value)
end
