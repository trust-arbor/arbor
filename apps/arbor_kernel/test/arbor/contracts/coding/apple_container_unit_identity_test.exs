defmodule Arbor.Contracts.Coding.AppleContainerUnitIdentityTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.AppleContainerUnitIdentity

  @moduletag :fast

  @suffix String.duplicate("a", 32)
  @resource_id "acu_v1_#{@suffix}"
  @unit_name "arbor-v1-#{@suffix}"
  @digest String.duplicate("f", 64)

  defp identity(overrides \\ %{}) do
    Map.merge(
      %{
        "resource_type" => "apple_container_unit",
        "resource_id" => @resource_id,
        "unit_name" => @unit_name,
        "execution_id" => "exec-1",
        "reserved_at_ms" => 1_700_000_000_000,
        "owner_status" => "known",
        "validation_resource_id" => "validation-1",
        "workspace_id" => "workspace-1",
        "task_id" => "task-1",
        "principal_id" => "principal-1",
        "source_record_digest" => @digest
      },
      overrides
    )
  end

  test "normalizes known identity and binds the canonical resource suffix" do
    assert {:ok, normalized} = AppleContainerUnitIdentity.normalize(identity())
    assert normalized["resource_id"] == @resource_id
    assert normalized["unit_name"] == @unit_name
    assert normalized["owner_status"] == "known"
  end

  test "normalizes legacy owner-unknown identity without inventing ownership" do
    unknown =
      identity(%{
        "owner_status" => "unknown",
        "validation_resource_id" => nil,
        "workspace_id" => nil,
        "task_id" => nil,
        "principal_id" => nil
      })

    assert {:ok, normalized} = AppleContainerUnitIdentity.normalize(unknown)
    assert normalized["owner_status"] == "unknown"
    assert normalized["task_id"] == nil

    assert {:error, :invalid_reconciliation_settle_fields} =
             AppleContainerUnitIdentity.normalize_settle_fields(%{
               "resource_id" => @resource_id,
               "expected_identity" => unknown
             })
  end

  test "settle fields accept atom aliases but reject duplicate aliases" do
    expected = identity()

    assert {:ok, @resource_id, normalized} =
             AppleContainerUnitIdentity.normalize_settle_fields(%{
               resource_id: @resource_id,
               expected_identity: expected
             })

    assert normalized["unit_name"] == @unit_name

    assert {:error, :invalid_reconciliation_settle_fields} =
             AppleContainerUnitIdentity.normalize_settle_fields(%{
               "resource_id" => @resource_id,
               :resource_id => @resource_id,
               "expected_identity" => expected
             })
  end

  test "rejects malformed producer bounds and digests" do
    assert {:error, _} =
             AppleContainerUnitIdentity.normalize(identity(%{"execution_id" => "has space"}))

    assert {:error, _} =
             AppleContainerUnitIdentity.normalize(
               identity(%{"task_id" => String.duplicate("x", 129)})
             )

    assert {:error, _} =
             AppleContainerUnitIdentity.normalize(
               identity(%{"source_record_digest" => String.duplicate("A", 64)})
             )

    assert {:error, _} =
             AppleContainerUnitIdentity.normalize(
               identity(%{"reserved_at_ms" => 9_007_199_254_740_992})
             )
  end
end
