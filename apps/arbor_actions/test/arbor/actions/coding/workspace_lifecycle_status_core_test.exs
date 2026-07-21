defmodule Arbor.Actions.Coding.WorkspaceLifecycleStatusCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Coding.WorkspaceLifecycleStatusCore, as: Core

  @max_failure_count_entries 8
  @forbidden_key_fragments ~w(
    task_id workspace_id resource_id principal_id repo_path worktree_path branch ref oid pid
    callback command capability path raw stdout stderr
  )

  test "aggregate table keeps lifecycle classes and cleanup paths disjoint" do
    status =
      Core.aggregate(%{
        leases: %{
          "live-1" => %{
            active: true,
            owner_death_retry_count: 2,
            owner_death_policy_error: :retention_identity_unavailable
          },
          "live-2" => %{
            active: true,
            owner_death_retry_count: 4,
            owner_death_retry_exhausted: true,
            owner_death_policy_error: :retention_cleanup_failed
          }
        },
        retained_by_id: %{
          "retained-1" => %{
            lifecycle: :retained,
            retry_count: 2,
            cleanup_failure: :marker_delete_failed
          },
          "orphan-1" => %{lifecycle: :active_orphaned, retry_count: 9},
          "discarding-1" => %{
            lifecycle: :discarding,
            retry_count: 3,
            cleanup_failure: :worktree_remove_failed
          },
          "discarding-2" => %{
            lifecycle: :discarding,
            retry_count: 8,
            dormant: true,
            cleanup_failure: :cleanup_retries_exhausted
          }
        },
        retention_blockers: %{
          "blocked-1" => %{cleanup_failure: :retention_identity_unavailable}
        },
        validation_resources: %{
          "owned-1" => %{resource_owner_pid: self()},
          "retrying-1" => %{
            resource_owner_pid: nil,
            resource_owner_cleanup_retry_count: 2
          },
          "dormant-1" => %{
            resource_owner_pid: nil,
            resource_owner_cleanup_retry_count: 4,
            resource_owner_cleanup_dormant: true
          }
        },
        retained_cleanup_retry_limit: 8,
        owner_death_retry_limit: 3,
        validation_owner_cleanup_retry_limit: 8,
        journal_status: :poisoned,
        journal_reason: {:invalid_record, "/private/repo", "RAW_STDOUT"}
      })

    assert status["active_leases"] == 2
    assert status["retained"] == 1
    assert status["active_orphaned"] == 1
    assert status["discarding_retrying"] == 1
    assert status["discarding_dormant"] == 1
    assert status["creation_blockers"] == 1
    assert status["validation_resources"] == 3
    assert status["validation_cleanup_retrying"] == 1
    assert status["validation_cleanup_dormant"] == 1
    assert status["owner_death_retrying"] == 1
    assert status["owner_death_dormant"] == 1

    assert status["cleanup"]["workspace"] == %{
             "retrying" => 2,
             "dormant" => 1,
             "retry_total" => 13,
             "max_retry_count" => 8,
             "configured_limit" => 8,
             "failure_counts" => [
               %{"category" => "cleanup_retries_exhausted", "count" => 1},
               %{"category" => "marker_delete_failed", "count" => 1},
               %{"category" => "worktree_remove_failed", "count" => 1}
             ]
           }

    assert status["cleanup"]["owner_death"]["retry_total"] == 6
    assert status["cleanup"]["owner_death"]["max_retry_count"] == 4
    assert status["cleanup"]["owner_death"]["configured_limit"] == 3

    assert status["cleanup"]["validation"] == %{
             "retrying" => 1,
             "dormant" => 1,
             "owned" => 1,
             "retry_total" => 6,
             "max_retry_count" => 4,
             "configured_limit" => 8,
             "failure_counts" => []
           }

    assert status["schema_version"] == 1

    assert status["journal"] == %{
             "status" => "degraded",
             "failure_category" => "cleanup_failed"
           }

    assert json_clean?(status)
    refute contains_forbidden_data?(status)
    assert Enum.sort_by(status["failure_counts"], & &1["category"]) == status["failure_counts"]
  end

  test "counts every resident active lease without silent truncation" do
    leases =
      for index <- 1..300, into: %{} do
        {"lease-#{index}", %{active: true}}
      end

    assert Core.aggregate(%{leases: leases})["active_leases"] == 300
  end

  test "empty and ready status have no phantom failure categories" do
    for snapshot <- [%{}, %{journal_status: :ready}] do
      status = Core.aggregate(snapshot)

      assert status["failure_counts"] == []
      assert status["cleanup"]["workspace"]["failure_counts"] == []
      assert status["cleanup"]["owner_death"]["failure_counts"] == []
      assert status["cleanup"]["validation"]["failure_counts"] == []
    end
  end

  test "security regression: lowercase sensitive failure values use the fixed category" do
    sensitive = "private_secret_token"

    status =
      Core.aggregate(%{
        retained_by_id: %{
          workspace: %{lifecycle: :retained, cleanup_failure: sensitive}
        },
        journal_status: :poisoned,
        journal_reason: sensitive
      })

    refute inspect(status) =~ sensitive
    assert status["failure_counts"] == [%{"category" => "cleanup_failed", "count" => 2}]
    assert status["journal"]["failure_category"] == "cleanup_failed"
  end

  test "failure counts remain bounded when many categories are present" do
    categories = ~w(
      branch_checked_out
      branch_checked_out_race
      branch_provenance_not_created
      branch_ref_oid_mismatch
      branch_tip_diverged
      discard_identity_unavailable
      marker_delete_failed
      retention_identity_unavailable
      worktree_remove_failed
    )

    retained_by_id =
      categories
      |> Enum.with_index()
      |> Map.new(fn {category, index} ->
        {"workspace-#{index}", %{lifecycle: :retained, cleanup_failure: category}}
      end)

    status = Core.aggregate(%{retained_by_id: retained_by_id})

    assert length(status["failure_counts"]) == @max_failure_count_entries

    assert Enum.find(status["failure_counts"], &(&1["category"] == "cleanup_failed")) ==
             %{"category" => "cleanup_failed", "count" => 2}

    assert Enum.sort_by(status["failure_counts"], & &1["category"]) == status["failure_counts"]
  end

  test "active_orphaned and unknown records do not enter workspace cleanup totals" do
    status =
      Core.aggregate(%{
        retained_by_id: %{
          orphan: %{
            lifecycle: :active_orphaned,
            retry_count: 31,
            dormant: true,
            cleanup_failure: :marker_delete_failed
          },
          unknown: %{retry_count: 31, dormant: true, cleanup_failure: :worktree_remove_failed}
        }
      })

    assert status["active_orphaned"] == 1

    assert status["cleanup"]["workspace"] == %{
             "retrying" => 0,
             "dormant" => 0,
             "retry_total" => 0,
             "max_retry_count" => 0,
             "configured_limit" => 0,
             "failure_counts" => []
           }
  end

  describe "journal status" do
    for {input, expected} <- [
          {:ready, "complete"},
          {"ready", "complete"},
          {:disabled, "disabled"},
          {"disabled", "disabled"},
          {:poisoned, "degraded"},
          {:malformed, "degraded"},
          {nil, "degraded"}
        ] do
      test "maps #{inspect(input)} to #{expected}" do
        assert Core.aggregate(%{journal_status: unquote(input)})["journal"] ==
                 %{"status" => unquote(expected)}
      end
    end

    test "ready with a reason is degraded" do
      assert Core.aggregate(%{journal_status: :ready, journal_reason: :malformed})["journal"] ==
               %{"status" => "degraded", "failure_category" => "cleanup_failed"}
    end
  end

  defp json_clean?(value) do
    cond do
      is_map(value) ->
        Enum.all?(value, fn {key, nested} -> is_binary(key) and json_clean?(nested) end)

      is_list(value) ->
        Enum.all?(value, &json_clean?/1)

      is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value) ->
        true

      true ->
        false
    end
  end

  defp contains_forbidden_data?(value) when is_map(value) do
    Enum.any?(value, fn {key, nested} ->
      key_text = key

      Enum.any?(@forbidden_key_fragments, &String.contains?(key_text, &1)) or
        contains_forbidden_data?(nested)
    end)
  end

  defp contains_forbidden_data?(value) when is_list(value),
    do: Enum.any?(value, &contains_forbidden_data?/1)

  defp contains_forbidden_data?(value) when is_binary(value),
    do: value in ["/private/repo", "RAW_STDOUT"]

  defp contains_forbidden_data?(_value), do: false
end
