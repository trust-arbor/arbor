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

  defp unique_server(label),
    do: {:global, {__MODULE__, label, System.unique_integer([:positive])}}
end
