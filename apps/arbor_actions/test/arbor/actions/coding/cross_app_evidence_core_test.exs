defmodule Arbor.Actions.Coding.CrossApp.EvidenceCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions
  alias Arbor.Actions.Coding.CrossApp.EvidenceCore
  alias Arbor.Contracts.Coding.ValidationCapacityHandoff

  @moduletag :fast

  @hex String.duplicate("c", 64)
  @base_oid String.duplicate("1", 40)
  @base_tree_oid String.duplicate("2", 40)
  @candidate_tree_oid String.duplicate("3", 40)
  @inv1 String.duplicate("a", 64)

  test "admit_identities/1 is closed, JSON-clean, and binds pre-commit head" do
    identities = identities()
    assert {:ok, admitted} = EvidenceCore.admit_identities(identities)
    assert admitted == identities
    assert admitted["candidate_head"] == admitted["base_commit"]
    assert admitted["candidate_tree_oid"] != admitted["base_tree_oid"]

    shuffled = identities |> Enum.shuffle() |> Map.new()
    assert {:ok, ^admitted} = EvidenceCore.admit_identities(shuffled)
    assert {:ok, ^admitted} = Actions.coding_cross_app_admit_identities(shuffled)

    drifted = Map.put(identities, "candidate_head", String.duplicate("7", 40))
    assert {:error, :identity_drift} = EvidenceCore.admit_identities(drifted)
    assert {:error, :malformed_state} = EvidenceCore.admit_identities(nil)
    assert {:error, :malformed_state} = EvidenceCore.admit_identities(%{task_id: "atom"})
  end

  test "lineage_key_for_identities/1 keeps historical xappc_ stored schema prefix" do
    identities = identities()
    assert {:ok, key} = EvidenceCore.lineage_key_for_identities(identities)
    assert key =~ ~r/\Axappc_[0-9a-f]{64}\z/
    assert {:ok, ^key} = Actions.coding_cross_app_identity_lineage_key(identities)

    shuffled = identities |> Enum.shuffle() |> Map.new()
    assert {:ok, ^key} = EvidenceCore.lineage_key_for_identities(shuffled)

    drifted = Map.put(identities, "task_id", "task_other_lineage")
    assert {:ok, other} = EvidenceCore.lineage_key_for_identities(drifted)
    assert other != key
  end

  test "digest/1 is canonical, JSON-clean, and facade-stable" do
    identities = identities()
    assert {:ok, digest} = EvidenceCore.digest(identities)
    assert digest =~ ~r/\A[0-9a-f]{64}\z/
    assert {:ok, ^digest} = EvidenceCore.digest(identities |> Enum.shuffle() |> Map.new())
    assert {:ok, ^digest} = Actions.coding_cross_app_digest(identities)

    assert {:ok, list_digest} = EvidenceCore.digest([])
    assert list_digest =~ ~r/\A[0-9a-f]{64}\z/
    assert {:error, :malformed_state} = EvidenceCore.digest(%{atom: :key})
  end

  defp identities do
    plan = [
      %{
        "index" => 1,
        "total" => 1,
        "count" => 1,
        "label" => "batch-1-of-1-n1-#{@inv1}",
        "inventory_sha256" => @inv1
      }
    ]

    {:ok, digest} = ValidationCapacityHandoff.ordered_plan_digest(plan)

    %{
      "task_id" => "task_evidence",
      "work_packet_digest" => "sha256:" <> @hex,
      "base_commit" => @base_oid,
      "base_tree_oid" => @base_tree_oid,
      "candidate_head" => @base_oid,
      "candidate_tree_oid" => @candidate_tree_oid,
      "validation_plan_digest" => digest,
      "toolchain_digest" => String.duplicate("3", 64),
      "dependency_baseline_digest" => String.duplicate("4", 64),
      "wrapper_digest" => String.duplicate("5", 64),
      "validator_id" => "coding_cross_app_validate",
      "principal_id" => "agent_principal",
      "configuration_digest" => String.duplicate("6", 64)
    }
  end
end
