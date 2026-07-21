defmodule Arbor.Actions.Coding.WorkspaceLifecycleStatusCore do
  @moduledoc """
  Pure reducer for bounded coding-workspace lifecycle status.

  The input is a snapshot of the registry's four primary state maps. The
  reducer never projects records, identifiers, paths, or raw failures. Failure
  terms are reduced to a finite, closed taxonomy and the resulting list is
  explicitly bounded.
  """

  @max_failure_count_entries 8
  @max_retry_count 32
  @unknown_failure_category "cleanup_failed"

  alias Arbor.Actions.Coding.WorkspaceBranchLifecycleCore, as: BranchLifecycle

  @spec aggregate(map()) :: map()
  def aggregate(snapshot) when is_map(snapshot) do
    leases = records(snapshot, :leases)
    retained = records(snapshot, :retained_by_id)
    blockers = records(snapshot, :retention_blockers)
    validation = records(snapshot, :validation_resources)

    workspace_records =
      Enum.filter(retained, &(lifecycle(&1) in [:retained, :discarding]))

    workspace_cleanup = cleanup_summary(workspace_records, workspace_retry_limit(snapshot))
    owner_death_cleanup = owner_death_summary(leases, owner_death_retry_limit(snapshot))
    validation_cleanup = validation_summary(validation, validation_retry_limit(snapshot))

    journal = journal_status(snapshot)

    journal_failures =
      case Map.get(snapshot, :journal_reason) do
        nil -> []
        reason -> [reason]
      end

    %{
      "schema_version" => 1,
      "active_leases" => count(leases, &(Map.get(&1, :active) == true)),
      "retained" => count(retained, &(lifecycle(&1) == :retained)),
      "active_orphaned" => count(retained, &(lifecycle(&1) == :active_orphaned)),
      "discarding_retrying" =>
        count(retained, &(lifecycle(&1) == :discarding and not dormant?(&1))),
      "discarding_dormant" => count(retained, &(lifecycle(&1) == :discarding and dormant?(&1))),
      "creation_blockers" => length(blockers),
      "validation_resources" => length(validation),
      "validation_cleanup_retrying" => validation_cleanup["retrying"],
      "validation_cleanup_dormant" => validation_cleanup["dormant"],
      "owner_death_retrying" => owner_death_cleanup["retrying"],
      "owner_death_dormant" => owner_death_cleanup["dormant"],
      "cleanup" => %{
        "workspace" => workspace_cleanup,
        "owner_death" => owner_death_cleanup,
        "validation" => validation_cleanup
      },
      "journal" => journal,
      "failure_counts" =>
        failure_counts(
          failure_values(workspace_records) ++
            failure_values(leases, :owner_death_policy_error) ++
            failure_values(blockers) ++ journal_failures
        )
    }
  end

  def aggregate(_snapshot), do: aggregate(%{})

  defp records(snapshot, key) do
    case Map.get(snapshot, key) do
      map when is_map(map) ->
        map |> Map.values() |> Enum.filter(&is_map/1)

      _ ->
        []
    end
  end

  defp count(records, predicate), do: Enum.count(records, predicate)

  defp lifecycle(record) do
    case Map.get(record, :lifecycle) do
      :retained -> :retained
      "retained" -> :retained
      :active_orphaned -> :active_orphaned
      "active_orphaned" -> :active_orphaned
      :discarding -> :discarding
      "discarding" -> :discarding
      _ -> :unknown
    end
  end

  defp dormant?(record), do: Map.get(record, :dormant, false) == true

  defp cleanup_summary(records, configured_limit) do
    records = Enum.filter(records, &(lifecycle(&1) in [:retained, :discarding]))
    retry_counts = Enum.map(records, &retry_count/1)

    %{
      "retrying" =>
        count(records, fn record ->
          lifecycle(record) in [:retained, :discarding] and retry_count(record) > 0 and
            not dormant?(record)
        end),
      "dormant" => count(records, &dormant?/1),
      "retry_total" => bounded_sum(retry_counts),
      "max_retry_count" => max_retry_count(retry_counts),
      "configured_limit" => configured_limit,
      "failure_counts" => failure_counts(failure_values(records))
    }
  end

  defp owner_death_summary(records, configured_limit) do
    retry_counts = Enum.map(records, &owner_death_retry_count/1)

    %{
      "retrying" =>
        count(records, fn record ->
          owner_death_retry_count(record) > 0 and not owner_death_dormant?(record)
        end),
      "dormant" => count(records, &owner_death_dormant?/1),
      "retry_total" => bounded_sum(retry_counts),
      "max_retry_count" => max_retry_count(retry_counts),
      "configured_limit" => configured_limit,
      "failure_counts" => failure_counts(failure_values(records, :owner_death_policy_error))
    }
  end

  defp validation_summary(records, configured_limit) do
    retry_counts = Enum.map(records, &validation_retry_count/1)

    %{
      "retrying" =>
        count(records, fn record ->
          validation_cleanup_status(record) == :retrying
        end),
      "dormant" => count(records, &(validation_cleanup_status(&1) == :dormant)),
      "owned" => count(records, &(validation_cleanup_status(&1) == :owned)),
      "retry_total" => bounded_sum(retry_counts),
      "max_retry_count" => max_retry_count(retry_counts),
      "configured_limit" => configured_limit,
      "failure_counts" => []
    }
  end

  defp validation_cleanup_status(record) do
    cond do
      Map.get(record, :resource_owner_cleanup_dormant, false) == true -> :dormant
      is_nil(Map.get(record, :resource_owner_pid)) -> :retrying
      true -> :owned
    end
  end

  defp retry_count(record), do: bounded_retry(Map.get(record, :retry_count))

  defp owner_death_retry_count(record),
    do: bounded_retry(Map.get(record, :owner_death_retry_count))

  defp validation_retry_count(record),
    do: bounded_retry(Map.get(record, :resource_owner_cleanup_retry_count))

  defp owner_death_dormant?(record) do
    Map.get(record, :owner_death_retry_exhausted, false) == true or
      Map.get(record, :owner_death_quarantine_state) in [
        :dormant,
        :validation_cleanup_dormant,
        "dormant",
        "validation_cleanup_dormant"
      ]
  end

  defp workspace_retry_limit(snapshot),
    do: bounded_limit(Map.get(snapshot, :retained_cleanup_retry_limit))

  defp owner_death_retry_limit(snapshot),
    do: bounded_limit(Map.get(snapshot, :owner_death_retry_limit))

  defp validation_retry_limit(snapshot),
    do: bounded_limit(Map.get(snapshot, :validation_owner_cleanup_retry_limit))

  defp bounded_retry(value) when is_integer(value) and value >= 0,
    do: min(value, @max_retry_count)

  defp bounded_retry(_value), do: 0

  defp bounded_limit(value) when is_integer(value) and value >= 0,
    do: min(value, @max_retry_count)

  defp bounded_limit(_value), do: 0

  defp bounded_sum(values), do: Enum.sum(values)

  defp max_retry_count([]), do: 0
  defp max_retry_count(values), do: Enum.max(values)

  defp failure_values(records, key \\ :cleanup_failure) do
    records
    |> Enum.map(&Map.get(&1, key))
    |> Enum.reject(&is_nil/1)
  end

  defp failure_counts(values) do
    counts =
      Enum.reduce(values, %{}, fn value, counts ->
        category = categorize_failure(value)
        Map.update(counts, category, 1, &(&1 + 1))
      end)

    counts
    |> bound_failure_counts()
    |> Enum.sort_by(fn {category, _count} -> category end)
    |> Enum.map(fn {category, count} -> %{"category" => category, "count" => count} end)
  end

  defp bound_failure_counts(counts) when map_size(counts) <= @max_failure_count_entries,
    do: counts

  defp bound_failure_counts(counts) do
    kept_categories =
      counts
      |> Map.keys()
      |> Enum.reject(&(&1 == @unknown_failure_category))
      |> Enum.sort()
      |> Enum.take(@max_failure_count_entries - 1)

    overflow_count =
      counts
      |> Enum.reject(fn {category, _count} -> category in kept_categories end)
      |> Enum.reduce(0, fn {_category, count}, total -> total + count end)

    counts
    |> Map.take(kept_categories)
    |> Map.put(@unknown_failure_category, overflow_count)
  end

  defp categorize_failure(value), do: BranchLifecycle.failure_category(value)

  defp journal_status(snapshot) do
    status = Map.get(snapshot, :journal_status)
    reason = Map.get(snapshot, :journal_reason)

    base =
      case status do
        status when status in [:ready, "ready"] and not is_nil(reason) ->
          %{"status" => "degraded"}

        status when status in [:ready, "ready"] ->
          %{"status" => "complete"}

        status when status in [:disabled, "disabled"] and not is_nil(reason) ->
          %{"status" => "degraded"}

        status when status in [:disabled, "disabled"] ->
          %{"status" => "disabled"}

        _ ->
          %{"status" => "degraded"}
      end

    case reason do
      nil -> base
      reason -> Map.put(base, "failure_category", categorize_failure(reason))
    end
  end
end
