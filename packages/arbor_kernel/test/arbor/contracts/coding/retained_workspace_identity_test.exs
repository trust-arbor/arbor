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

  test "accepts the coherent complete proof matrix with SHA-1 and SHA-256 OIDs" do
    sha1 = String.duplicate("d", 40)
    sha256 = String.duplicate("e", 64)

    complete_cases = [
      {"retained with an observed branch", complete_proof()},
      {"archive phase at SHA-1 settlement tip", discarding_proof("archive", sha1)},
      {"worktree phase at SHA-256 settlement tip", discarding_proof("worktree", sha256)},
      {"branch phase with tip still present", discarding_proof("branch", sha1)},
      {"branch phase after branch removal",
       discarding_proof("branch", sha256, %{"status" => "absent", "oid" => nil})}
    ]

    Enum.each(complete_cases, fn {label, proof} ->
      assert {:ok, normalized} = RetainedWorkspaceIdentity.normalize(proof), label
      assert normalized == proof, label
      assert RetainedWorkspaceIdentity.settlement_ready?(proof), label
    end)
  end

  test "rejects incoherent complete lifecycle, discard phase, and tip combinations" do
    tip = String.duplicate("d", 40)
    divergent = String.duplicate("e", 40)

    invalid_cases = [
      {"retained identity carrying a discard phase",
       complete_proof()
       |> Map.put("discard_phase", "archive")
       |> Map.put("settlement_tip", tip)},
      {"discarding identity without a phase",
       complete_proof()
       |> Map.put("lifecycle", "discarding")
       |> Map.put("settlement_tip", tip)},
      {"discarding identity without a settlement tip",
       complete_proof()
       |> Map.put("lifecycle", "discarding")
       |> Map.put("discard_phase", "archive")},
      {"archive phase with a divergent branch OID",
       discarding_proof("archive", tip, %{"status" => "present", "oid" => divergent})},
      {"worktree phase with an absent branch",
       discarding_proof("worktree", tip, %{"status" => "absent", "oid" => nil})},
      {"branch phase with a divergent branch OID",
       discarding_proof("branch", tip, %{"status" => "present", "oid" => divergent})},
      {"retained identity with an absent branch",
       put_in(complete_proof(), ["branch_observation"], %{"status" => "absent", "oid" => nil})},
      {"active lifecycle", Map.put(complete_proof(), "lifecycle", "active")},
      {"active-orphaned lifecycle", Map.put(complete_proof(), "lifecycle", "active_orphaned")},
      {"creating lifecycle", Map.put(complete_proof(), "lifecycle", "creating")}
    ]

    Enum.each(invalid_cases, fn {label, proof} ->
      assert {:error, _} = RetainedWorkspaceIdentity.normalize(proof), label
      refute RetainedWorkspaceIdentity.settlement_ready?(proof), label
    end)
  end

  test "admits only coherent unavailable and marker proof shapes" do
    unavailable = unavailable_proof()

    assert {:ok, ^unavailable} = RetainedWorkspaceIdentity.normalize(unavailable)
    refute RetainedWorkspaceIdentity.settlement_ready?(unavailable)

    Enum.each(
      [
        {"discard phase", Map.put(unavailable, "discard_phase", "archive")},
        {"settlement tip", Map.put(unavailable, "settlement_tip", String.duplicate("d", 40))},
        {"discard phase and settlement tip",
         unavailable
         |> Map.put("discard_phase", "branch")
         |> Map.put("settlement_tip", String.duplicate("d", 40))},
        {"workspace digest", Map.put(unavailable, "workspace_digest", String.duplicate("a", 64))},
        {"marker digest", Map.put(unavailable, "marker_digest", String.duplicate("b", 64))},
        {"repository digest",
         Map.put(unavailable, "repository_digest", String.duplicate("c", 64))},
        {"present branch observation",
         Map.put(unavailable, "branch_observation", %{
           "status" => "present",
           "oid" => String.duplicate("d", 40)
         })},
        {"absent branch observation",
         Map.put(unavailable, "branch_observation", %{"status" => "absent", "oid" => nil})}
      ],
      fn {label, proof} ->
        assert {:error, _} = RetainedWorkspaceIdentity.normalize(proof), label
        refute RetainedWorkspaceIdentity.settlement_ready?(proof), label
      end
    )

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

  defp discarding_proof(phase, settlement_tip) do
    discarding_proof(
      phase,
      settlement_tip,
      %{"status" => "present", "oid" => settlement_tip}
    )
  end

  defp discarding_proof(phase, settlement_tip, branch_observation) do
    complete_proof()
    |> Map.merge(%{
      "lifecycle" => "discarding",
      "discard_phase" => phase,
      "settlement_tip" => settlement_tip,
      "branch_observation" => branch_observation
    })
  end
end
