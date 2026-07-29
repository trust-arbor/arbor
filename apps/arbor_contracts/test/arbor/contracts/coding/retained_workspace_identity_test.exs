defmodule Arbor.Contracts.Coding.RetainedWorkspaceIdentityTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.RetainedWorkspaceIdentity

  @moduletag :fast

  test "normalizes the exact legacy identity shape for archived audit" do
    legacy = legacy_identity()

    assert {:ok, normalized} = RetainedWorkspaceIdentity.normalize(legacy)
    assert normalized == legacy
    refute RetainedWorkspaceIdentity.settlement_ready?(normalized)

    assert {:error, _} =
             RetainedWorkspaceIdentity.normalize(Map.put(legacy, "proof_status", "complete"))

    assert {:error, _} = RetainedWorkspaceIdentity.normalize(Map.delete(legacy, "expires_at"))
  end

  test "normalizes an exact complete version-2 proof and requires lower-case OIDs" do
    proof = complete_proof()

    assert {:ok, normalized} = RetainedWorkspaceIdentity.normalize(proof)
    assert normalized == proof
    assert RetainedWorkspaceIdentity.settlement_ready?(proof)

    assert {:error, _} =
             RetainedWorkspaceIdentity.normalize(
               put_in(
                 proof,
                 ["branch_observation", "oid"],
                 String.upcase(proof["branch_observation"]["oid"])
               )
             )

    assert {:error, _} =
             RetainedWorkspaceIdentity.normalize(
               put_in(proof, ["branch_observation", "oid"], String.duplicate("a", 39))
             )

    assert {:error, _} =
             RetainedWorkspaceIdentity.normalize(
               put_in(proof, ["settlement_tip"], String.duplicate("a", 65))
             )
  end

  test "rejects atom and string aliases, unsupported versions, and extra proof fields" do
    proof = complete_proof()

    assert {:error, _} =
             RetainedWorkspaceIdentity.normalize(Map.put(proof, :identity_version, 2))

    assert {:error, _} =
             RetainedWorkspaceIdentity.normalize(Map.put(proof, "identity_version", 3))

    assert {:error, _} = RetainedWorkspaceIdentity.normalize(Map.put(proof, "path", "/secret"))
    assert {:error, _} = RetainedWorkspaceIdentity.normalize(Map.delete(proof, "marker_digest"))
  end

  test "admits only coherent complete and unavailable proof shapes" do
    unavailable = unavailable_proof()

    assert {:ok, ^unavailable} = RetainedWorkspaceIdentity.normalize(unavailable)
    refute RetainedWorkspaceIdentity.settlement_ready?(unavailable)

    assert {:error, _} =
             RetainedWorkspaceIdentity.normalize(
               put_in(complete_proof(), ["branch_observation"], %{
                 "status" => "unavailable",
                 "oid" => nil
               })
             )

    assert {:error, _} =
             RetainedWorkspaceIdentity.normalize(
               unavailable
               |> Map.put("workspace_digest", String.duplicate("a", 64))
               |> Map.put("proof_status", "complete")
             )

    assert {:error, _} =
             RetainedWorkspaceIdentity.normalize(
               put_in(complete_proof(), ["branch_observation"], %{
                 "status" => "absent",
                 "oid" => String.duplicate("a", 40)
               })
             )

    assert {:error, _} =
             RetainedWorkspaceIdentity.normalize(
               complete_proof()
               |> Map.put("marker_source", "durable")
               |> Map.put("marker_digest", nil)
             )
  end

  defp legacy_identity do
    %{
      "resource_type" => "retained_workspace_record",
      "resource_id" => "retained-1",
      "task_id" => "task-1",
      "principal_id" => "principal-1",
      "lifecycle" => "retained",
      "active" => false,
      "ownership" => "owned",
      "branch_provenance" => "created",
      "cleanup_armed" => false,
      "dormant" => false,
      "retry_count" => 0,
      "retry_limit" => 3,
      "expires_at" => "2026-07-22T18:00:00Z"
    }
  end

  defp complete_proof do
    legacy_identity()
    |> Map.merge(%{
      "identity_version" => RetainedWorkspaceIdentity.identity_version(),
      "proof_status" => "complete",
      "marker_source" => "disabled",
      "workspace_digest" => String.duplicate("a", 64),
      "marker_digest" => nil,
      "repository_digest" => String.duplicate("b", 64),
      "branch_observation" => %{"status" => "present", "oid" => String.duplicate("c", 40)},
      "discard_phase" => nil,
      "settlement_tip" => nil
    })
  end

  defp unavailable_proof do
    complete_proof()
    |> Map.merge(%{
      "proof_status" => "unavailable",
      "marker_source" => "unavailable",
      "workspace_digest" => nil,
      "marker_digest" => nil,
      "repository_digest" => nil,
      "branch_observation" => %{"status" => "unavailable", "oid" => nil}
    })
  end
end
