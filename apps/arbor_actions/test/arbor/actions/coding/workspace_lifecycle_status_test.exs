defmodule Arbor.Actions.Coding.WorkspaceLifecycleStatusTest do
  use Arbor.Actions.ActionCase, async: true

  alias Arbor.Actions
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry

  @moduletag :fast

  test "poisoned and disabled registries keep lifecycle status available" do
    poisoned = unique_server("poisoned")
    disabled = unique_server("disabled")

    poisoned_spec =
      %{
        WorkspaceLeaseRegistry.child_spec(name: poisoned, retention_journal: :malformed)
        | id: {:workspace_status_poisoned, self()}
      }

    disabled_spec =
      %{
        WorkspaceLeaseRegistry.child_spec(name: disabled, retention_journal: :disabled)
        | id: {:workspace_status_disabled, self()}
      }

    start_supervised!(poisoned_spec)
    start_supervised!(disabled_spec)

    assert {:ok, poisoned_status} = WorkspaceLeaseRegistry.lifecycle_status(server: poisoned)
    assert {:ok, disabled_status} = WorkspaceLeaseRegistry.lifecycle_status(server: disabled)
    assert poisoned_status["journal"]["status"] == "degraded"
    assert poisoned_status["journal"]["failure_category"] == "cleanup_failed"
    assert disabled_status["journal"] == %{"status" => "disabled"}
    assert poisoned_status["active_leases"] == 0
    assert disabled_status["active_leases"] == 0
  end

  test "lifecycle status action is registered, read-only, and executable" do
    assert Workspace.LifecycleStatus in Actions.list_actions().coding
    assert Workspace.LifecycleStatus in Actions.list_exposed_actions().coding

    assert {:ok, Workspace.LifecycleStatus} =
             Actions.name_to_module("coding.workspace.lifecycle_status")

    assert {:ok, Workspace.LifecycleStatus} =
             Actions.name_to_module("coding_workspace_lifecycle_status")

    assert Actions.canonical_uri_for(Workspace.LifecycleStatus, %{}) ==
             "arbor://action/coding/workspace/status"

    assert Actions.tool_name_to_canonical_uri("coding_workspace_lifecycle_status") ==
             {:ok, "arbor://action/coding/workspace/status"}

    assert Workspace.LifecycleStatus.name() == "coding_workspace_lifecycle_status"
    assert Workspace.LifecycleStatus.taint_roles() == %{}
    assert Workspace.LifecycleStatus.effect_class() == :read
    assert {:ok, status} = Workspace.LifecycleStatus.run(%{}, %{})
    assert status["journal"]["status"] in ["complete", "disabled", "degraded"]
    assert Workspace.json_clean?(status)
  end

  test "facade delegates lifecycle status to a selected registry" do
    server = unique_server("facade")
    start_supervised!({WorkspaceLeaseRegistry, name: server, retention_journal: :disabled})

    assert {:ok, status} = Actions.coding_workspace_lifecycle_status(server: server)
    assert status["journal"] == %{"status" => "disabled"}
  end

  test "security regression: lifecycle status collapses sensitive failure strings" do
    server = unique_server("failure_taxonomy")
    start_supervised!({WorkspaceLeaseRegistry, name: server, retention_journal: :disabled})

    sensitive = "private_secret_token"

    replace_registry_state(server, fn state ->
      %{
        state
        | retained_by_id: %{
            "workspace" => %{lifecycle: :retained, cleanup_failure: sensitive}
          },
          retention_journal:
            state.retention_journal
            |> Map.put(:status, :poisoned)
            |> Map.put(:reason, sensitive)
      }
    end)

    assert {:ok, status} = Actions.coding_workspace_lifecycle_status(server: server)
    encoded = Jason.encode!(status)

    refute String.contains?(encoded, sensitive)
    assert status["failure_counts"] == [%{"category" => "cleanup_failed", "count" => 2}]
    assert status["journal"]["failure_category"] == "cleanup_failed"
  end

  test "lifecycle status keeps failure_counts bounded through the public facade" do
    server = unique_server("failure_bound")
    start_supervised!({WorkspaceLeaseRegistry, name: server, retention_journal: :disabled})

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

    replace_registry_state(server, &Map.put(&1, :retained_by_id, retained_by_id))

    assert {:ok, status} = Actions.coding_workspace_lifecycle_status(server: server)
    assert length(status["failure_counts"]) == 8

    assert Enum.find(status["failure_counts"], &(&1["category"] == "cleanup_failed")) ==
             %{"category" => "cleanup_failed", "count" => 2}
  end

  defp unique_server(label),
    do: {:global, {__MODULE__, label, System.unique_integer([:positive])}}

  defp replace_registry_state({:global, name}, update) do
    name
    |> :global.whereis_name()
    |> :sys.replace_state(update)
  end
end
