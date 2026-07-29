defmodule Arbor.Actions.MixAppleContainerOwnerBindingTest do
  @moduledoc """
  Focused regression: Mix unit_owner comes from the validation resource
  (WorkspaceLeaseRegistry lease lineage), not from arbitrary action context.
  """

  use ExUnit.Case, async: true

  alias Arbor.Actions.Mix, as: MixAction

  @moduletag :fast

  test "unit owner is projected only from the validation resource fields" do
    resource = %{
      resource_id: "validation_from_registry",
      workspace_id: "workspace_from_lease",
      task_id: "task_from_lease",
      principal_id: "principal_from_lease"
    }

    assert {:ok, owner} = MixAction.unit_owner_from_validation_resource(resource)

    assert owner == %{
             validation_resource_id: "validation_from_registry",
             workspace_id: "workspace_from_lease",
             task_id: "task_from_lease",
             principal_id: "principal_from_lease"
           }

    assert {:ok, ^owner} =
             MixAction.unit_owner_from_validation_resource(%{
               "resource_id" => "validation_from_registry",
               "workspace_id" => "workspace_from_lease",
               "task_id" => "task_from_lease",
               "principal_id" => "principal_from_lease"
             })

    assert {:error, :ambiguous_unit_owner} =
             resource
             |> Map.put("task_id", "task_from_context")
             |> MixAction.unit_owner_from_validation_resource()
  end

  test "incomplete validation resource fails closed before spawn" do
    incomplete = %{
      resource_id: "validation_x",
      workspace_id: "workspace_x",
      task_id: nil,
      principal_id: "principal_x"
    }

    assert {:error, :incomplete_unit_owner} =
             MixAction.unit_owner_from_validation_resource(incomplete)

    assert {:error, :validation_resource_required} =
             MixAction.unit_owner_from_validation_resource(nil)
  end
end
