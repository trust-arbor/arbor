defmodule Arbor.Agent.Orchestration.ApprovalInventoryProjection do
  @moduledoc """
  Pure, bounded projection of pending approvals reported by approval backends.

  The projection intentionally excludes descriptions, context, metadata, and
  backend-specific values. It is reconciliation evidence, not an approval
  queue or a source of authority.
  """

  alias Arbor.Agent.Orchestration.PendingApproval
  alias Arbor.Contracts.Security.CapabilityUri

  @schema_version 1
  @max_id_bytes 256
  @max_resource_bytes 256
  @task_id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @statuses ~w(pending evaluating)

  @type entry ::
          {:approval, :consensus | :interaction, PendingApproval.t(), String.t() | nil}
          | {:malformed, :consensus | :interaction}
          | {:ignored, :consensus | :interaction}

  @spec from_entries([entry()], map(), pos_integer(), map()) :: map()
  def from_entries(entries, filters, max_items, backend_evidence)
      when is_list(entries) and is_map(filters) and is_integer(max_items) and max_items > 0 and
             is_map(backend_evidence) do
    {approvals, counts} = reduce_entries(entries)
    matching = Enum.filter(approvals, &matches?(&1, filters))
    ordered = Enum.sort_by(matching, &{&1["approval_id"], &1["source"]})
    returned = Enum.take(ordered, max_items)
    matching_count = length(matching)
    returned_count = length(returned)
    truncated_count = max(matching_count - returned_count, 0)
    backend_truncated = Map.get(backend_evidence, "truncated", false) == true

    %{
      "schema_version" => @schema_version,
      "storage" => %{
        "durability" => "volatile",
        "authority" => "approval_backends",
        "read_only" => true
      },
      "bounds" => %{
        "max_items" => max_items,
        "max_backend_entries" => Map.get(backend_evidence, "max_entries", 0)
      },
      "filters" => %{
        "task_id" => Map.get(filters, :task_id),
        "agent_id" => Map.get(filters, :agent_id),
        "principal_id" => Map.get(filters, :principal_id),
        "resource_uri" => Map.get(filters, :resource_uri)
      },
      "counts" => %{
        "observed" => Map.get(counts, :observed, 0),
        "matching" => matching_count,
        "returned" => returned_count,
        "filtered_out" => Map.get(counts, :valid, 0) - matching_count,
        "ignored" => Map.get(counts, :ignored, 0),
        "malformed" => Map.get(counts, :malformed, 0),
        "duplicates" => Map.get(counts, :duplicates, 0),
        "quarantined" => Map.get(counts, :malformed, 0) + Map.get(counts, :duplicates, 0),
        "truncated" => truncated_count,
        "backend_omitted" => Map.get(backend_evidence, "omitted", 0)
      },
      "backend_counts" => Map.get(backend_evidence, "sources", %{}),
      "truncated" => backend_truncated or truncated_count > 0,
      "approvals" => returned
    }
  end

  def from_entries(_entries, _filters, _max_items, _backend_evidence),
    do: invalid_inventory()

  defp reduce_entries(entries) do
    identity_counts =
      Enum.reduce(entries, %{}, fn
        {:approval, source, %PendingApproval{} = approval, _task_id}, counts ->
          case approval_identity(source, approval) do
            {:ok, identity} -> Map.update(counts, identity, 1, &(&1 + 1))
            :error -> counts
          end

        _entry, counts ->
          counts
      end)

    counts = Map.put(initial_counts(), :observed, length(entries))

    Enum.reduce(entries, {[], counts}, fn entry, {approvals, counts} ->
      case entry do
        {:approval, source, %PendingApproval{} = approval, task_id} ->
          case approval_identity(source, approval) do
            {:ok, identity} ->
              if Map.get(identity_counts, identity, 0) > 1 do
                {approvals, Map.update!(counts, :duplicates, &(&1 + 1))}
              else
                project_or_quarantine(approvals, counts, source, approval, task_id)
              end

            _ ->
              project_or_quarantine(approvals, counts, source, approval, task_id)
          end

        {:malformed, _source} ->
          {approvals, Map.update!(counts, :malformed, &(&1 + 1))}

        {:ignored, _source} ->
          {approvals, Map.update!(counts, :ignored, &(&1 + 1))}

        _ ->
          {approvals, Map.update!(counts, :malformed, &(&1 + 1))}
      end
    end)
  end

  defp initial_counts, do: %{observed: 0, valid: 0, ignored: 0, malformed: 0, duplicates: 0}

  defp project_or_quarantine(approvals, counts, source, approval, task_id) do
    case project_approval(source, approval, task_id) do
      {:ok, projected} ->
        {[projected | approvals], Map.update!(counts, :valid, &(&1 + 1))}

      :malformed ->
        {approvals, Map.update!(counts, :malformed, &(&1 + 1))}
    end
  end

  defp approval_identity(source, %PendingApproval{} = approval) do
    with {:ok, source} <- source_string(source),
         {:ok, approval_id} <- required_string(approval.id, @max_id_bytes) do
      {:ok, {source, approval_id}}
    else
      _ -> :error
    end
  end

  defp project_approval(source, %PendingApproval{} = approval, task_id) do
    with {:ok, approval_id} <- required_string(approval.id, @max_id_bytes),
         {:ok, task_id} <- optional_task_id(task_id),
         {:ok, agent_id} <- optional_string(approval.agent_id, @max_id_bytes),
         {:ok, principal_id} <- optional_string(approval.principal_id, @max_id_bytes),
         {:ok, approver_id} <- optional_string(approval.approver_id, @max_id_bytes),
         {:ok, resource_uri} <- optional_resource_uri(approval.resource_uri),
         {:ok, action} <- optional_value_string(approval.action, @max_id_bytes),
         {:ok, status} <- status_string(approval.status),
         {:ok, created_at} <- optional_timestamp(approval.created_at),
         {:ok, source_name} <- source_string(source) do
      {:ok,
       %{
         "approval_id" => approval_id,
         "source" => source_name,
         "task_id" => task_id,
         "agent_id" => agent_id,
         "principal_id" => principal_id,
         "approver_id" => approver_id,
         "resource_uri" => resource_uri,
         "action" => action,
         "status" => status,
         "created_at" => created_at
       }}
    else
      _ -> :malformed
    end
  rescue
    _ -> :malformed
  catch
    _, _ -> :malformed
  end

  defp source_string(:consensus), do: {:ok, "consensus"}
  defp source_string(:interaction), do: {:ok, "interaction"}
  defp source_string(_source), do: :error

  defp matches?(approval, filters) do
    matches_value?(Map.get(filters, :task_id), approval["task_id"]) and
      matches_value?(Map.get(filters, :agent_id), approval["agent_id"]) and
      matches_principal?(Map.get(filters, :principal_id), approval) and
      matches_resource?(Map.get(filters, :resource_uri), approval["resource_uri"])
  end

  defp matches_value?(nil, _actual), do: true
  defp matches_value?(expected, actual), do: expected == actual

  defp matches_principal?(nil, _approval), do: true

  defp matches_principal?(expected, approval),
    do: expected in [approval["principal_id"], approval["approver_id"]]

  defp matches_resource?(nil, _resource_uri), do: true

  defp matches_resource?(prefix, resource_uri) do
    CapabilityUri.prefix_match?(prefix, resource_uri)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp required_string(value, max_bytes) do
    case optional_string(value, max_bytes) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> :error
    end
  end

  defp optional_string(nil, _max_bytes), do: {:ok, nil}

  defp optional_string(value, max_bytes)
       when is_binary(value) and byte_size(value) <= max_bytes do
    if String.valid?(value) and not String.contains?(value, <<0>>) do
      {:ok, value}
    else
      :error
    end
  end

  defp optional_string(_value, _max_bytes), do: :error

  defp optional_value_string(nil, _max_bytes), do: {:ok, nil}

  defp optional_value_string(value, max_bytes) when is_atom(value),
    do: optional_string(Atom.to_string(value), max_bytes)

  defp optional_value_string(value, max_bytes), do: optional_string(value, max_bytes)

  defp optional_resource_uri(nil), do: {:ok, nil}

  defp optional_resource_uri(resource_uri)
       when is_binary(resource_uri) and byte_size(resource_uri) <= @max_resource_bytes do
    if CapabilityUri.valid?(resource_uri), do: {:ok, resource_uri}, else: :error
  end

  defp optional_resource_uri(_resource_uri), do: :error

  defp optional_task_id(nil), do: {:ok, nil}

  defp optional_task_id(task_id)
       when is_binary(task_id) and byte_size(task_id) <= @max_id_bytes do
    if String.valid?(task_id) and Regex.match?(@task_id_pattern, task_id),
      do: {:ok, task_id},
      else: :error
  end

  defp optional_task_id(_task_id), do: :error

  defp status_string(status) when is_atom(status), do: status_string(Atom.to_string(status))

  defp status_string(status) when status in @statuses, do: {:ok, status}
  defp status_string(_status), do: :error

  defp optional_timestamp(nil), do: {:ok, nil}
  defp optional_timestamp(%DateTime{} = value), do: {:ok, DateTime.to_iso8601(value)}

  defp optional_timestamp(value) when is_binary(value) and byte_size(value) <= 64 do
    if String.valid?(value) and value != "" and not String.contains?(value, <<0>>) do
      case DateTime.from_iso8601(value) do
        {:ok, datetime, _offset} -> {:ok, DateTime.to_iso8601(datetime)}
        _ -> :error
      end
    else
      :error
    end
  end

  defp optional_timestamp(_value), do: :error

  defp invalid_inventory do
    %{
      "schema_version" => @schema_version,
      "storage" => %{
        "durability" => "volatile",
        "authority" => "approval_backends",
        "read_only" => true
      },
      "bounds" => %{"max_items" => 0, "max_backend_entries" => 0},
      "filters" => %{
        "task_id" => nil,
        "agent_id" => nil,
        "principal_id" => nil,
        "resource_uri" => nil
      },
      "counts" => %{
        "observed" => 0,
        "matching" => 0,
        "returned" => 0,
        "filtered_out" => 0,
        "ignored" => 0,
        "malformed" => 1,
        "duplicates" => 0,
        "quarantined" => 1,
        "truncated" => 0,
        "backend_omitted" => 0
      },
      "backend_counts" => %{},
      "truncated" => true,
      "approvals" => []
    }
  end
end
