defmodule Arbor.Orchestrator.CodingPlan.ReconciliationCore do
  @moduledoc """
  Pure first-slice reconciliation of coding resources against task observations.

  The inputs are the JSON-clean public task and coding-resource projections.
  This module does not interpret paths, PIDs, process terms, authorities, or
  arbitrary metadata. It emits evidence only; an imperative shell can later
  decide whether a validated manifest is still current before applying it.
  """

  alias Arbor.Contracts.Coding.PendingApprovalResourceId
  alias Arbor.Contracts.Coding.ReconciliationManifest
  alias Arbor.Contracts.Security.CapabilityUri

  @schema_version 1
  @max_tasks 1_000
  @max_resources 1_000
  @max_acp_sessions 1_000
  @max_approvals 1_000
  @max_json_bytes 1_000_000
  # Match the producer collection bounds; the document byte limit remains
  # the independent protection against large records.
  @max_json_collection_items 1_000
  @resource_types ~w(live_workspace_lease retained_workspace_record validation_resource quarantine)
  @resource_order %{
    "live_workspace_lease" => 0,
    "retained_workspace_record" => 1,
    "validation_resource" => 2,
    "quarantine" => 3,
    "acp_managed_session" => 4,
    "pending_approval" => 5
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
  @source_acp_session_fields ~w(
    worker_session_id provider_session_id provider model status pooled return_to_pool
    task_id principal_id owner_present owner_alive session_alive close_cleanup_in_progress
  )
  @source_approval_fields ~w(
    resource_id approval_id source task_id agent_id principal_id approver_id
    resource_uri action status created_at
  )
  @approval_count_fields ~w(
    observed matching returned filtered_out ignored malformed duplicates quarantined
    truncated backend_omitted
  )
  @acp_count_fields ~w(
    observed matching returned filtered_out truncated malformed duplicates quarantined
    quarantine_returned quarantine_truncated
  )
  @scope_fields ~w(task_id principal_id agent_id state)
  @pending_approval_statuses ~w(pending evaluating)

  @type state :: %{
          required(:observed_at) => String.t(),
          required(:scope) => map(),
          required(:task_inventory) => map(),
          required(:resource_inventory) => map(),
          required(:acp_session_inventory) => map(),
          required(:pending_approval_inventory) => map(),
          required(:observation_digest) => map()
        }

  @doc "Construct normalized reconciliation state from bounded JSON observations."
  @spec new(map() | keyword()) :: {:ok, state()} | {:error, term()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    with {:ok, attrs} <-
           normalize_object(
             attrs,
             ~w(
               task_inventory resource_inventory acp_session_inventory
               pending_approval_inventory observed_at scope
             )
           ),
         {:ok, task_inventory} <- normalize_task_inventory(fetch(attrs, "task_inventory")),
         {:ok, resource_inventory} <-
           normalize_resource_inventory(fetch(attrs, "resource_inventory")),
         {:ok, acp_session_inventory} <-
           normalize_acp_session_inventory(
             fetch(attrs, "acp_session_inventory"),
             resource_inventory["filters"]
           ),
         {:ok, pending_approval_inventory} <-
           normalize_pending_approval_inventory(
             fetch(attrs, "pending_approval_inventory"),
             resource_inventory["filters"]
           ),
         :ok <-
           validate_scope_consistency(
             task_inventory["filters"],
             resource_inventory["filters"],
             acp_session_inventory["filters"],
             pending_approval_inventory["filters"]
           ),
         :ok <-
           no_truncation(
             task_inventory,
             resource_inventory,
             acp_session_inventory,
             pending_approval_inventory
           ),
         {:ok, observed_at} <- normalize_observed_at(fetch(attrs, "observed_at")),
         {:ok, scope} <-
           normalize_scope(
             fetch(attrs, "scope"),
             task_inventory,
             resource_inventory,
             acp_session_inventory,
             pending_approval_inventory
           ),
         {:ok, observation_digest} <-
           observation_digest(
             task_inventory,
             resource_inventory,
             acp_session_inventory,
             pending_approval_inventory
           ),
         :ok <-
           bounded_document?(%{
             "task_inventory" => task_inventory,
             "resource_inventory" => resource_inventory,
             "acp_session_inventory" => acp_session_inventory,
             "pending_approval_inventory" => pending_approval_inventory
           }) do
      {:ok,
       %{
         observed_at: observed_at,
         scope: scope,
         task_inventory: task_inventory,
         resource_inventory: resource_inventory,
         acp_session_inventory: acp_session_inventory,
         pending_approval_inventory: pending_approval_inventory,
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
        acp_session_inventory: acp_session_inventory,
        pending_approval_inventory: pending_approval_inventory,
        observation_digest: observation_digest
      }) do
    task_index = Map.new(task_inventory["tasks"], &{&1["task_id"], &1})
    journal_status = resource_inventory["journal"]["status"]

    workspace_decisions =
      Enum.map(
        resource_inventory["resources"],
        &decide(&1, task_index, journal_status, observed_at)
      )

    acp_decisions =
      Enum.map(
        acp_session_inventory["sessions"],
        &decide_acp_session(&1, task_index, journal_status)
      )

    approval_decisions =
      Enum.map(
        pending_approval_inventory["approvals"],
        &decide_pending_approval(&1, task_index, journal_status)
      )

    decisions =
      (workspace_decisions ++ acp_decisions ++ approval_decisions)
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
  @spec reconcile(
          map() | keyword(),
          map() | keyword(),
          term(),
          map() | keyword(),
          map() | keyword() | nil,
          map() | keyword() | nil
        ) ::
          {:ok, map(), String.t()} | {:error, term()}
  def reconcile(
        task_inventory,
        resource_inventory,
        observed_at,
        scope \\ %{},
        acp_session_inventory \\ nil,
        pending_approval_inventory \\ nil
      ) do
    attrs = %{
      "task_inventory" => task_inventory,
      "resource_inventory" => resource_inventory,
      "acp_session_inventory" => acp_session_inventory,
      "pending_approval_inventory" => pending_approval_inventory,
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

  @doc false
  @spec empty_acp_inventory() :: map()
  def empty_acp_inventory, do: empty_acp_inventory_for(%{"task_id" => nil, "principal_id" => nil})

  @doc false
  @spec empty_pending_approval_inventory() :: map()
  def empty_pending_approval_inventory,
    do: empty_pending_approval_inventory_for(%{"task_id" => nil, "principal_id" => nil})

  defp empty_acp_inventory_for(filters) do
    %{
      "schema_version" => @schema_version,
      "storage" => %{"durability" => "volatile"},
      "filters" => %{
        "task_id" => filters["task_id"],
        "principal_id" => filters["principal_id"]
      },
      "max_items" => @max_acp_sessions,
      "truncated" => false,
      "counts" => %{
        "observed" => 0,
        "matching" => 0,
        "returned" => 0,
        "filtered_out" => 0,
        "truncated" => 0,
        "malformed" => 0,
        "duplicates" => 0,
        "quarantined" => 0,
        "quarantine_returned" => 0,
        "quarantine_truncated" => 0
      },
      "sessions" => [],
      "quarantine" => []
    }
  end

  defp empty_pending_approval_inventory_for(filters) do
    %{
      "schema_version" => @schema_version,
      "storage" => %{
        "durability" => "volatile",
        "authority" => "approval_backends",
        "read_only" => true
      },
      "bounds" => %{
        "max_items" => @max_approvals,
        "max_backend_entries" => @max_approvals
      },
      "filters" => %{
        "task_id" => filters["task_id"],
        "agent_id" => nil,
        "principal_id" => filters["principal_id"],
        "principal_scope" => "subject",
        "resource_uri" => nil
      },
      "counts" => %{
        "observed" => 0,
        "matching" => 0,
        "returned" => 0,
        "filtered_out" => 0,
        "ignored" => 0,
        "malformed" => 0,
        "duplicates" => 0,
        "quarantined" => 0,
        "truncated" => 0,
        "backend_omitted" => 0
      },
      "backend_counts" => %{
        "consensus" => %{"observed" => 0, "omitted" => 0, "truncated" => false},
        "interaction" => %{"observed" => 0, "omitted" => 0, "truncated" => false}
      },
      "truncated" => false,
      "approvals" => []
    }
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

  defp normalize_acp_session_inventory(nil, resource_filters),
    do:
      normalize_acp_session_inventory(
        empty_acp_inventory_for(resource_filters),
        resource_filters
      )

  defp normalize_acp_session_inventory(inventory, _resource_filters)
       when is_map(inventory) and not is_struct(inventory) do
    with {:ok, inventory} <-
           object(
             inventory,
             ~w(schema_version storage filters max_items truncated counts sessions quarantine)
           ),
         :ok <-
           exact(
             inventory,
             ~w(schema_version storage filters max_items truncated counts sessions quarantine)
           ),
         :ok <- version(inventory["schema_version"]),
         :ok <- exact(inventory["storage"], ~w(durability)),
         :ok <- value(inventory["storage"]["durability"], "volatile"),
         {:ok, filters} <- normalize_acp_filters(inventory["filters"]),
         :ok <- positive_count(inventory["max_items"], @max_acp_sessions),
         :ok <- boolean_value(inventory["truncated"]),
         {:ok, counts} <- normalize_acp_counts(inventory["counts"]),
         {:ok, sessions} <- normalize_acp_sessions(inventory["sessions"], counts["returned"]),
         :ok <- normalize_acp_quarantine(inventory["quarantine"], counts),
         :ok <- validate_acp_filter_membership(sessions, filters),
         :ok <- validate_acp_count_invariants(counts, length(sessions)) do
      {:ok,
       %{
         inventory
         | "filters" => filters,
           "counts" => counts,
           "sessions" => sessions,
           "quarantine" => []
       }}
    end
  end

  defp normalize_acp_session_inventory(_inventory, _resource_filters),
    do: {:error, :malformed_acp_session_inventory}

  defp normalize_pending_approval_inventory(nil, resource_filters),
    do:
      normalize_pending_approval_inventory(
        empty_pending_approval_inventory_for(resource_filters),
        resource_filters
      )

  defp normalize_pending_approval_inventory(inventory, resource_filters)
       when is_map(inventory) and not is_struct(inventory) do
    with {:ok, inventory} <-
           object(
             inventory,
             ~w(schema_version storage bounds filters counts backend_counts truncated approvals)
           ),
         :ok <-
           exact(
             inventory,
             ~w(schema_version storage bounds filters counts backend_counts truncated approvals)
           ),
         :ok <- version(inventory["schema_version"]),
         :ok <- exact(inventory["storage"], ~w(durability authority read_only)),
         :ok <- value(inventory["storage"]["durability"], "volatile"),
         :ok <- value(inventory["storage"]["authority"], "approval_backends"),
         :ok <- value(inventory["storage"]["read_only"], true),
         {:ok, bounds} <- normalize_approval_bounds(inventory["bounds"]),
         {:ok, filters} <- normalize_approval_filters(inventory["filters"], resource_filters),
         :ok <- boolean_value(inventory["truncated"]),
         true <- inventory["truncated"] == false,
         {:ok, counts} <- normalize_approval_counts(inventory["counts"], bounds),
         {:ok, backend_counts} <-
           normalize_approval_backend_counts(inventory["backend_counts"], bounds, counts),
         {:ok, approvals} <-
           normalize_approvals(inventory["approvals"], counts["returned"], bounds),
         :ok <- validate_approval_filter_membership(approvals, filters),
         :ok <- validate_approval_count_invariants(counts, length(approvals)) do
      {:ok,
       %{
         inventory
         | "bounds" => bounds,
           "filters" => filters,
           "counts" => counts,
           "backend_counts" => backend_counts,
           "approvals" => approvals
       }}
    else
      false -> {:error, :malformed_pending_approval_inventory}
      error -> error
    end
  end

  defp normalize_pending_approval_inventory(_inventory, _resource_filters),
    do: {:error, :malformed_pending_approval_inventory}

  defp normalize_approval_bounds(bounds) when is_map(bounds) do
    with {:ok, bounds} <- object(bounds, ~w(max_items max_backend_entries)),
         :ok <- exact(bounds, ~w(max_items max_backend_entries)),
         :ok <- positive_count(bounds["max_items"], @max_approvals),
         :ok <- positive_count(bounds["max_backend_entries"], @max_approvals) do
      {:ok, bounds}
    end
  end

  defp normalize_approval_bounds(_bounds), do: {:error, :malformed_pending_approval_inventory}

  defp normalize_approval_filters(filters, _resource_filters) when is_map(filters) do
    with {:ok, filters} <-
           object(filters, ~w(task_id agent_id principal_id principal_scope resource_uri)),
         :ok <- exact(filters, ~w(task_id agent_id principal_id principal_scope resource_uri)),
         :ok <- optional_approval_source_id(filters["task_id"]),
         :ok <- optional_approval_source_id(filters["agent_id"]),
         :ok <- optional_approval_source_id(filters["principal_id"]),
         true <- filters["principal_scope"] == "subject",
         true <- is_nil(filters["agent_id"]),
         true <- is_nil(filters["resource_uri"]),
         :ok <- optional_resource_uri_value(filters["resource_uri"]) do
      {:ok, filters}
    else
      false -> {:error, :inconsistent_approval_filters}
      error -> error
    end
  end

  defp normalize_approval_filters(_filters, _resource_filters),
    do: {:error, :malformed_pending_approval_inventory}

  defp normalize_approval_counts(counts, bounds) when is_map(counts) do
    aggregate_cap = 2 * bounds["max_backend_entries"]

    with {:ok, counts} <- object(counts, @approval_count_fields),
         :ok <- exact(counts, @approval_count_fields),
         :ok <- count_at_most(counts["observed"], aggregate_cap),
         :ok <- count_at_most(counts["matching"], aggregate_cap),
         :ok <- count_at_most(counts["returned"], bounds["max_items"]),
         :ok <- count_at_most(counts["filtered_out"], aggregate_cap),
         :ok <- count_at_most(counts["ignored"], aggregate_cap),
         :ok <- count_at_most(counts["malformed"], aggregate_cap),
         :ok <- count_at_most(counts["duplicates"], aggregate_cap),
         :ok <- count_at_most(counts["quarantined"], aggregate_cap),
         :ok <- count_at_most(counts["truncated"], aggregate_cap),
         :ok <- count_at_most(counts["backend_omitted"], aggregate_cap) do
      {:ok, counts}
    end
  end

  defp normalize_approval_counts(_counts, _bounds),
    do: {:error, :malformed_pending_approval_inventory}

  defp normalize_approval_backend_counts(backend_counts, bounds, counts)
       when is_map(backend_counts) do
    with {:ok, backend_counts} <- object(backend_counts, ~w(consensus interaction)),
         :ok <- exact(backend_counts, ~w(consensus interaction)),
         {:ok, consensus} <- normalize_backend_source_counts(backend_counts["consensus"], bounds),
         {:ok, interaction} <-
           normalize_backend_source_counts(backend_counts["interaction"], bounds),
         true <- consensus["omitted"] == 0 and interaction["omitted"] == 0,
         true <- consensus["truncated"] == false and interaction["truncated"] == false,
         true <- consensus["observed"] + interaction["observed"] == counts["observed"],
         true <- counts["backend_omitted"] == consensus["omitted"] + interaction["omitted"] do
      {:ok, %{"consensus" => consensus, "interaction" => interaction}}
    else
      false -> {:error, :inconsistent_backend_counts}
      error -> error
    end
  end

  defp normalize_approval_backend_counts(_backend_counts, _bounds, _counts),
    do: {:error, :inconsistent_backend_counts}

  defp normalize_backend_source_counts(source, bounds) when is_map(source) do
    with {:ok, source} <- object(source, ~w(observed omitted truncated)),
         :ok <- exact(source, ~w(observed omitted truncated)),
         :ok <- count_at_most(source["observed"], bounds["max_backend_entries"]),
         :ok <- count_at_most(source["omitted"], bounds["max_backend_entries"]),
         :ok <- boolean_value(source["truncated"]) do
      {:ok, source}
    end
  end

  defp normalize_backend_source_counts(_source, _bounds),
    do: {:error, :inconsistent_backend_counts}

  defp validate_approval_count_invariants(counts, returned) do
    if counts["returned"] == returned and
         counts["truncated"] == 0 and
         counts["backend_omitted"] == 0 and
         counts["malformed"] == 0 and
         counts["duplicates"] == 0 and
         counts["quarantined"] == 0 and
         counts["matching"] == counts["returned"] + counts["truncated"] and
         counts["quarantined"] == counts["malformed"] + counts["duplicates"] and
         counts["observed"] ==
           counts["matching"] + counts["filtered_out"] + counts["malformed"] +
             counts["ignored"] + counts["duplicates"],
       do: :ok,
       else: {:error, :inconsistent_approval_counts}
  end

  defp normalize_approvals(approvals, returned, bounds) when is_list(approvals) do
    if length(approvals) <= bounds["max_items"] and length(approvals) == returned do
      with {:ok, normalized} <- normalize_approval_entries(approvals),
           :ok <- reject_duplicate_approval_identities(normalized),
           :ok <- reject_duplicate_ids(normalized, "resource_id") do
        {:ok, Enum.sort_by(normalized, &approval_sort_key/1)}
      end
    else
      {:error, :malformed_pending_approval_inventory}
    end
  end

  defp normalize_approvals(_approvals, _returned, _bounds),
    do: {:error, :malformed_pending_approval_inventory}

  defp normalize_approval_entries(approvals) do
    Enum.reduce_while(approvals, {:ok, []}, fn approval, {:ok, acc} ->
      case normalize_approval(approval) do
        {:ok, approval} -> {:cont, {:ok, [approval | acc]}}
        error -> {:halt, error}
      end
    end)
    |> reverse_ok()
  end

  defp normalize_approval(approval) when is_map(approval) and not is_struct(approval) do
    with {:ok, approval} <- object(approval, @source_approval_fields),
         :ok <- exact(approval, @source_approval_fields),
         {:ok, approval_id} <- required_approval_text(approval["approval_id"]),
         {:ok, source} <-
           enum_value_result(approval["source"], PendingApprovalResourceId.sources()),
         {:ok, resource_id} <- PendingApprovalResourceId.resource_id(source, approval_id),
         true <- approval["resource_id"] == resource_id,
         :ok <- optional_approval_source_id(approval["task_id"]),
         :ok <- optional_approval_source_id(approval["agent_id"]),
         :ok <- optional_approval_source_id(approval["principal_id"]),
         :ok <- optional_approval_source_id(approval["approver_id"]),
         :ok <- optional_resource_uri_value(approval["resource_uri"]),
         :ok <- optional_approval_text(approval["action"]),
         :ok <- enum_value(approval["status"], @pending_approval_statuses),
         :ok <- optional_timestamp_value(approval["created_at"]) do
      {:ok, Map.put(approval, "resource_id", resource_id)}
    else
      false ->
        {:error, :malformed_pending_approval_inventory}

      {:error, :invalid_pending_approval_resource_id} ->
        {:error, :malformed_pending_approval_inventory}

      error ->
        error
    end
  end

  defp normalize_approval(_approval), do: {:error, :malformed_pending_approval_inventory}

  defp validate_approval_filter_membership(approvals, filters) do
    if Enum.all?(approvals, fn approval ->
         (is_nil(filters["task_id"]) or approval["task_id"] == filters["task_id"]) and
           (is_nil(filters["principal_id"]) or
              approval["principal_id"] == filters["principal_id"])
       end),
       do: :ok,
       else: {:error, :inconsistent_approval_filters}
  end

  defp reject_duplicate_approval_identities(approvals) do
    identities =
      Enum.map(approvals, fn approval -> {approval["source"], approval["approval_id"]} end)

    if length(identities) == length(Enum.uniq(identities)),
      do: :ok,
      else: {:error, {:duplicate, "approval_identity"}}
  end

  defp approval_sort_key(approval), do: {approval["approval_id"], approval["source"]}

  defp required_approval_text(value)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= 256 do
    if String.valid?(value) and not String.contains?(value, <<0>>),
      do: {:ok, value},
      else: {:error, :invalid_approval_text}
  end

  defp required_approval_text(_value), do: {:error, :invalid_approval_text}

  defp optional_approval_text(nil), do: :ok

  defp optional_approval_text(value) when is_binary(value) and byte_size(value) <= 256 do
    if String.valid?(value) and not String.contains?(value, <<0>>),
      do: :ok,
      else: {:error, :invalid_approval_text}
  end

  defp optional_approval_text(_value), do: {:error, :invalid_approval_text}

  defp optional_resource_uri_value(nil), do: :ok

  defp optional_resource_uri_value(resource_uri)
       when is_binary(resource_uri) and byte_size(resource_uri) <= 256 do
    if CapabilityUri.valid?(resource_uri), do: :ok, else: {:error, :invalid_resource_uri}
  rescue
    _ -> {:error, :invalid_resource_uri}
  catch
    _, _ -> {:error, :invalid_resource_uri}
  end

  defp optional_resource_uri_value(_resource_uri), do: {:error, :invalid_resource_uri}

  defp normalize_acp_filters(filters) when is_map(filters) do
    with {:ok, filters} <- object(filters, ~w(task_id principal_id)),
         :ok <- exact(filters, ~w(task_id principal_id)),
         :ok <- optional_id(filters["task_id"]),
         :ok <- optional_id(filters["principal_id"]) do
      {:ok, filters}
    end
  end

  defp normalize_acp_filters(_filters), do: {:error, :malformed_acp_filters}

  defp normalize_acp_counts(counts) when is_map(counts) do
    with {:ok, counts} <- object(counts, @acp_count_fields),
         :ok <- exact(counts, @acp_count_fields),
         :ok <- count_at_most(counts["observed"], @max_acp_sessions),
         :ok <- count_at_most(counts["matching"], @max_acp_sessions),
         :ok <- count_at_most(counts["returned"], @max_acp_sessions),
         :ok <- count_at_most(counts["filtered_out"], @max_acp_sessions),
         :ok <- count_at_most(counts["truncated"], @max_acp_sessions),
         :ok <- count_at_most(counts["malformed"], @max_acp_sessions),
         :ok <- count_at_most(counts["duplicates"], @max_acp_sessions),
         :ok <- count_at_most(counts["quarantined"], @max_acp_sessions),
         :ok <- count_at_most(counts["quarantine_returned"], @max_acp_sessions),
         :ok <- count_at_most(counts["quarantine_truncated"], @max_acp_sessions) do
      {:ok, counts}
    end
  end

  defp normalize_acp_counts(_counts), do: {:error, :malformed_acp_counts}

  defp validate_acp_count_invariants(counts, returned) do
    if counts["returned"] == returned and
         counts["truncated"] == 0 and
         counts["malformed"] == 0 and
         counts["duplicates"] == 0 and
         counts["quarantined"] == 0 and
         counts["quarantine_returned"] == 0 and
         counts["quarantine_truncated"] == 0 and
         counts["matching"] == counts["returned"] + counts["truncated"] and
         counts["observed"] ==
           counts["malformed"] + counts["duplicates"] + counts["filtered_out"] +
             counts["matching"],
       do: :ok,
       else: {:error, :inconsistent_acp_counts}
  end

  defp normalize_acp_quarantine(quarantine, counts) when is_list(quarantine) do
    if quarantine == [] and counts["quarantined"] == 0 and
         counts["quarantine_returned"] == 0 and counts["quarantine_truncated"] == 0,
       do: :ok,
       else: {:error, :malformed_acp_quarantine}
  end

  defp normalize_acp_quarantine(_quarantine, _counts),
    do: {:error, :malformed_acp_quarantine}

  defp normalize_acp_sessions(sessions, returned) when is_list(sessions) do
    if length(sessions) <= @max_acp_sessions and length(sessions) == returned do
      with {:ok, normalized} <- normalize_acp_session_entries(sessions),
           :ok <- reject_duplicate_ids(normalized, "worker_session_id"),
           :ok <- reject_duplicate_provider_sessions(normalized) do
        {:ok, Enum.sort_by(normalized, &acp_session_sort_key/1)}
      end
    else
      {:error, :malformed_acp_sessions}
    end
  end

  defp normalize_acp_sessions(_sessions, _returned), do: {:error, :malformed_acp_sessions}

  defp normalize_acp_session_entries(sessions) do
    Enum.reduce_while(sessions, {:ok, []}, fn session, {:ok, acc} ->
      case normalize_acp_session(session) do
        {:ok, session} -> {:cont, {:ok, [session | acc]}}
        error -> {:halt, error}
      end
    end)
    |> reverse_ok()
  end

  defp normalize_acp_session(session) when is_map(session) and not is_struct(session) do
    with {:ok, session} <- object(session, @source_acp_session_fields),
         :ok <- exact(session, @source_acp_session_fields),
         {:ok, worker_session_id} <- acp_id(session["worker_session_id"]),
         :ok <- optional_acp_text(session["provider_session_id"]),
         :ok <- acp_text(session["provider"]),
         :ok <- optional_acp_text(session["model"]),
         :ok <- acp_text(session["status"]),
         :ok <- boolean_value(session["pooled"]),
         :ok <- boolean_value(session["return_to_pool"]),
         :ok <- optional_acp_id(session["task_id"]),
         :ok <- optional_acp_id(session["principal_id"]),
         :ok <- boolean_value(session["owner_present"]),
         :ok <- boolean_value(session["owner_alive"]),
         :ok <- boolean_value(session["session_alive"]),
         :ok <- boolean_value(session["close_cleanup_in_progress"]),
         :ok <- valid_acp_session_state(session) do
      {:ok, Map.put(session, "worker_session_id", worker_session_id)}
    end
  end

  defp normalize_acp_session(_session), do: {:error, :malformed_acp_session}

  defp validate_acp_filter_membership(sessions, filters) do
    if Enum.all?(sessions, fn session ->
         (is_nil(filters["task_id"]) or session["task_id"] == filters["task_id"]) and
           (is_nil(filters["principal_id"]) or
              session["principal_id"] == filters["principal_id"])
       end),
       do: :ok,
       else: {:error, :inconsistent_acp_filters}
  end

  defp valid_acp_session_state(%{
         "owner_present" => false,
         "owner_alive" => true
       }),
       do: {:error, :inconsistent_acp_liveness}

  defp valid_acp_session_state(%{
         "close_cleanup_in_progress" => true,
         "status" => status
       })
       when status != "closing",
       do: {:error, :inconsistent_acp_close_state}

  defp valid_acp_session_state(_session), do: :ok

  defp acp_session_sort_key(session) do
    {session["worker_session_id"], session["provider"] || "",
     session["provider_session_id"] || ""}
  end

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

  defp decide_acp_session(session, task_index, journal_status) do
    task_id = session["task_id"]
    principal_id = session["principal_id"]
    task = Map.get(task_index, task_id)
    owner_status = acp_owner_status(session, task)
    task_state = if is_map(task), do: task["state"], else: nil

    {decision, reason} =
      cond do
        is_nil(task_id) or is_nil(principal_id) ->
          {"quarantine", "missing_task_or_principal_provenance"}

        is_nil(task) ->
          {"quarantine", "missing_task"}

        task_state in @live_states and owner_status == "live" ->
          {"keep", "live_task_owner_alive"}

        task_state in @live_states ->
          {"retry", "live_task_owner_dead"}

        task_state in @terminal_states ->
          {"settle", "terminal_active_resource"}

        true ->
          {"quarantine", "ambiguous_provenance"}
      end

    %{
      "schema_version" => @schema_version,
      "resource_type" => "acp_managed_session",
      "resource_id" => session["worker_session_id"],
      "task_id" => task_id,
      "principal_id" => principal_id,
      "decision" => decision,
      "reason" => reason,
      "expected_identity" => acp_expected_identity(session),
      "evidence" => %{
        "task_presence" => if(is_map(task), do: "observed", else: "absent"),
        "task_state" => task_state,
        "owner_status" => owner_status,
        "journal_status" => journal_status
      }
    }
  end

  defp acp_expected_identity(session) do
    %{
      "resource_type" => "acp_managed_session",
      "resource_id" => session["worker_session_id"],
      "worker_session_id" => session["worker_session_id"],
      "provider_session_id" => session["provider_session_id"],
      "provider" => session["provider"],
      "model" => session["model"],
      "status" => session["status"],
      "pooled" => session["pooled"],
      "return_to_pool" => session["return_to_pool"],
      "task_id" => session["task_id"],
      "principal_id" => session["principal_id"],
      "owner_present" => session["owner_present"],
      "owner_alive" => session["owner_alive"],
      "session_alive" => session["session_alive"],
      "close_cleanup_in_progress" => session["close_cleanup_in_progress"]
    }
  end

  defp decide_pending_approval(approval, task_index, journal_status) do
    task_id = approval["task_id"]
    principal_id = approval["principal_id"]
    task = Map.get(task_index, task_id)
    owner_status = owner_status(task)
    task_state = if is_map(task), do: task["state"], else: nil

    {decision, reason} =
      cond do
        is_nil(task_id) or is_nil(principal_id) ->
          {"quarantine", "missing_task_or_principal_provenance"}

        is_nil(task) ->
          {"quarantine", "missing_task"}

        not is_nil(approval["agent_id"]) and approval["agent_id"] != task["agent_id"] ->
          {"quarantine", "ambiguous_provenance"}

        task_state in @live_states and owner_status == "live" ->
          {"keep", "live_task_owner_alive"}

        task_state in @live_states ->
          {"retry", "live_task_owner_dead"}

        task_state in @terminal_states ->
          {"settle", "terminal_active_resource"}

        true ->
          {"quarantine", "ambiguous_provenance"}
      end

    %{
      "schema_version" => @schema_version,
      "resource_type" => "pending_approval",
      "resource_id" => approval["resource_id"],
      "task_id" => task_id,
      "principal_id" => principal_id,
      "decision" => decision,
      "reason" => reason,
      "expected_identity" => pending_approval_expected_identity(approval),
      "evidence" => %{
        "task_presence" => if(is_map(task), do: "observed", else: "absent"),
        "task_state" => task_state,
        "owner_status" => owner_status,
        "journal_status" => journal_status
      }
    }
  end

  defp pending_approval_expected_identity(approval) do
    %{
      "resource_type" => "pending_approval",
      "resource_id" => approval["resource_id"],
      "approval_id" => approval["approval_id"],
      "source" => approval["source"],
      "task_id" => approval["task_id"],
      "agent_id" => approval["agent_id"],
      "principal_id" => approval["principal_id"],
      "approver_id" => approval["approver_id"],
      "resource_uri" => approval["resource_uri"],
      "action" => approval["action"],
      "status" => approval["status"],
      "created_at" => approval["created_at"]
    }
  end

  defp acp_owner_status(session, task) do
    session_owner_status =
      cond do
        session["owner_present"] == true and session["owner_alive"] == true and
          session["session_alive"] == true and
            session["close_cleanup_in_progress"] == false ->
          "live"

        session["owner_present"] == false ->
          "absent"

        true ->
          "dead"
      end

    if is_map(task) and owner_status(task) != "live", do: "dead", else: session_owner_status
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

  defp decision_sort_key(
         %{
           "resource_type" => "pending_approval",
           "expected_identity" => identity
         } = decision
       ) do
    {Map.fetch!(@resource_order, "pending_approval"), "pending_approval", identity["approval_id"],
     identity["source"], decision["resource_id"], decision["task_id"] || "",
     decision["principal_id"] || ""}
  end

  defp decision_sort_key(decision) do
    {Map.get(@resource_order, decision["resource_type"], 99), decision["resource_type"],
     decision["resource_id"], decision["task_id"] || "", decision["principal_id"] || ""}
  end

  defp resource_sort_key(resource) do
    {Map.get(@resource_order, resource["resource_type"], 99), resource["resource_type"],
     resource["resource_id"]}
  end

  defp observation_digest(tasks, resources, acp_sessions, approvals) do
    task_digest = sha256(canonical_json(tasks))
    resource_digest = sha256(canonical_json(resources))

    source = %{
      "task_inventory" => tasks,
      "resource_inventory" => resources,
      "acp_session_inventory" => acp_sessions,
      "pending_approval_inventory" => approvals
    }

    {:ok,
     %{
       "task_inventory_sha256" => task_digest,
       "resource_inventory_sha256" => resource_digest,
       "source_sha256" => sha256(canonical_json(source))
     }}
  end

  defp normalize_scope(
         nil,
         task_inventory,
         resource_inventory,
         acp_session_inventory,
         pending_approval_inventory
       ),
       do:
         normalize_scope(
           effective_scope(
             task_inventory,
             resource_inventory,
             acp_session_inventory,
             pending_approval_inventory
           ),
           task_inventory,
           resource_inventory,
           acp_session_inventory,
           pending_approval_inventory
         )

  defp normalize_scope(
         scope,
         task_inventory,
         resource_inventory,
         acp_session_inventory,
         pending_approval_inventory
       )
       when is_map(scope) and map_size(scope) == 0,
       do:
         normalize_scope(
           nil,
           task_inventory,
           resource_inventory,
           acp_session_inventory,
           pending_approval_inventory
         )

  defp normalize_scope(
         scope,
         task_inventory,
         resource_inventory,
         acp_session_inventory,
         pending_approval_inventory
       )
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
           if(
             normalized ==
               effective_scope(
                 task_inventory,
                 resource_inventory,
                 acp_session_inventory,
                 pending_approval_inventory
               ),
             do: :ok,
             else: {:error, :inconsistent_scope}
           ) do
      {:ok, normalized}
    end
  end

  defp normalize_scope(
         _scope,
         _task_inventory,
         _resource_inventory,
         _acp_session_inventory,
         _pending_approval_inventory
       ),
       do: {:error, :malformed_scope}

  defp effective_scope(
         task_inventory,
         resource_inventory,
         acp_session_inventory,
         pending_approval_inventory
       ) do
    task_filters = task_inventory["filters"]
    resource_filters = resource_inventory["filters"]
    acp_filters = acp_session_inventory["filters"]
    approval_filters = pending_approval_inventory["filters"]

    %{
      "task_id" =>
        resource_filters["task_id"] || acp_filters["task_id"] || approval_filters["task_id"] ||
          task_filters["task_id"],
      "principal_id" =>
        resource_filters["principal_id"] || acp_filters["principal_id"] ||
          approval_filters["principal_id"],
      "agent_id" => nil,
      "state" => nil
    }
  end

  defp validate_scope_consistency(
         task_filters,
         resource_filters,
         acp_filters,
         approval_filters
       ) do
    cond do
      not is_nil(task_filters["agent_id"]) ->
        {:error, :unsupported_task_scope}

      not is_nil(task_filters["state"]) ->
        {:error, :unsupported_task_scope}

      not is_nil(task_filters["task_id"]) and
          task_filters["task_id"] != resource_filters["task_id"] ->
        {:error, :inconsistent_scope}

      acp_filters["task_id"] != resource_filters["task_id"] ->
        {:error, :inconsistent_scope}

      acp_filters["principal_id"] != resource_filters["principal_id"] ->
        {:error, :inconsistent_scope}

      approval_filters["task_id"] != resource_filters["task_id"] ->
        {:error, :inconsistent_scope}

      approval_filters["principal_id"] != resource_filters["principal_id"] ->
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

  defp no_truncation(
         task_inventory,
         resource_inventory,
         acp_session_inventory,
         pending_approval_inventory
       ) do
    cond do
      task_inventory["truncated"] or resource_inventory["truncated"] or
        acp_session_inventory["truncated"] or pending_approval_inventory["truncated"] ->
        {:error, :truncated_observation}

      task_inventory["counts"]["truncated"] > 0 or resource_inventory["counts"]["truncated"] > 0 or
        acp_session_inventory["counts"]["truncated"] > 0 or
          pending_approval_inventory["counts"]["truncated"] > 0 ->
        {:error, :truncated_observation}

      task_inventory["counts"]["malformed"] > 0 ->
        {:error, :malformed_task_inventory}

      acp_session_inventory["counts"]["malformed"] > 0 or
        acp_session_inventory["counts"]["duplicates"] > 0 or
          acp_session_inventory["counts"]["quarantined"] > 0 ->
        {:error, :malformed_acp_session_inventory}

      pending_approval_inventory["counts"]["malformed"] > 0 or
        pending_approval_inventory["counts"]["duplicates"] > 0 or
        pending_approval_inventory["counts"]["quarantined"] > 0 or
          pending_approval_inventory["counts"]["backend_omitted"] > 0 ->
        {:error, :malformed_pending_approval_inventory}

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

  # These mirror Arbor.AI.AcpManaged.SessionRegistry's JSON projection boundary.
  defp acp_id(value)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= 256 do
    if String.valid?(value) and String.trim(value) == value and
         not String.match?(value, ~r/[\x00-\x1F\x7F]/),
       do: {:ok, value},
       else: {:error, :invalid_acp_id}
  end

  defp acp_id(_value), do: {:error, :invalid_acp_id}

  defp optional_acp_id(nil), do: :ok

  defp optional_acp_id(value),
    do: if(match?({:ok, _}, acp_id(value)), do: :ok, else: {:error, :invalid_acp_id})

  defp optional_approval_source_id(nil), do: :ok

  defp optional_approval_source_id(value)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= 256 do
    if String.valid?(value) and String.trim(value) == value and
         not String.match?(value, ~r/[\x00-\x1F\x7F]/),
       do: :ok,
       else: {:error, :invalid_approval_source_id}
  end

  defp optional_approval_source_id(_value), do: {:error, :invalid_approval_source_id}

  defp acp_text(value) when is_binary(value) and byte_size(value) <= 256 do
    if String.valid?(value) and not String.contains?(value, <<0>>),
      do: :ok,
      else: {:error, :invalid_acp_text}
  end

  defp acp_text(_value), do: {:error, :invalid_acp_text}

  defp optional_acp_text(nil), do: :ok
  defp optional_acp_text(value), do: acp_text(value)

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

  defp reject_duplicate_provider_sessions(entries) do
    identities =
      Enum.flat_map(entries, fn session ->
        case session["provider_session_id"] do
          nil -> []
          provider_session_id -> [{session["provider"], provider_session_id}]
        end
      end)

    if length(Enum.uniq(identities)) == length(identities),
      do: :ok,
      else: {:error, {:duplicate, "provider_session_id"}}
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
