defmodule Arbor.Contracts.Coding.ReconciliationManifestTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.{
    AppleContainerUnitIdentity,
    PendingApprovalResourceId,
    ReconciliationDecision,
    ReconciliationManifest,
    RetainedWorkspaceIdentity
  }

  @moduletag :fast

  # Frozen pre-slice workspace decision/manifest attrs for byte-for-byte v1 regression.
  @legacy_workspace_decision %{
    "schema_version" => 1,
    "resource_type" => "live_workspace_lease",
    "resource_id" => "lease-1",
    "task_id" => "task-1",
    "principal_id" => "principal-1",
    "decision" => "keep",
    "reason" => "live_task_owner_alive",
    "expected_identity" => %{
      "resource_type" => "live_workspace_lease",
      "resource_id" => "lease-1",
      "task_id" => "task-1",
      "principal_id" => "principal-1",
      "lifecycle" => "active",
      "active" => true,
      "ownership" => "owned",
      "branch_provenance" => "created",
      "cleanup_armed" => true,
      "dormant" => false,
      "retry_count" => 0,
      "retry_limit" => 3,
      "expires_at" => nil
    },
    "evidence" => %{
      "task_presence" => "observed",
      "task_state" => "running",
      "owner_status" => "live",
      "journal_status" => "complete"
    }
  }

  @legacy_workspace_manifest %{
    "schema_version" => 1,
    "observed_at" => "2026-07-22T17:00:00Z",
    "scope" => %{"task_id" => nil, "principal_id" => nil, "agent_id" => nil, "state" => nil},
    "observation_digest" => %{
      "task_inventory_sha256" => String.duplicate("a", 64),
      "resource_inventory_sha256" => String.duplicate("b", 64),
      "source_sha256" => String.duplicate("c", 64)
    },
    "decisions" => [@legacy_workspace_decision],
    "counts" => %{
      "resources" => 1,
      "keep" => 1,
      "retry" => 0,
      "settle" => 0,
      "quarantine" => 0,
      "remove" => 0
    }
  }

  # Golden digest for the frozen legacy workspace manifest (stable across additive ACP identity).
  @legacy_workspace_manifest_digest "91d0037a21275760b4175a5c8e0f6272339705af035d192b1456de3e232a6ed6"

  test "constructs a closed decision and manifest" do
    assert ReconciliationDecision.decisions() == ~w(keep retry settle quarantine remove)

    assert {:ok, decision} = ReconciliationDecision.new(valid_decision())
    assert decision.decision == "keep"

    assert ReconciliationDecision.to_map(decision)["expected_identity"]["resource_id"] ==
             "lease-1"

    attrs = %{
      "schema_version" => 1,
      "observed_at" => "2026-07-22T17:00:00Z",
      "scope" => %{"task_id" => nil, "principal_id" => nil, "agent_id" => nil, "state" => nil},
      "observation_digest" => %{
        "task_inventory_sha256" => String.duplicate("a", 64),
        "resource_inventory_sha256" => String.duplicate("b", 64),
        "source_sha256" => String.duplicate("c", 64)
      },
      "decisions" => [ReconciliationDecision.to_map(decision)],
      "counts" => %{
        "resources" => 1,
        "keep" => 1,
        "retry" => 0,
        "settle" => 0,
        "quarantine" => 0,
        "remove" => 0
      }
    }

    assert {:ok, manifest} = ReconciliationManifest.new(attrs)
    assert {:ok, digest} = ReconciliationManifest.digest(manifest)
    assert String.match?(digest, ~r/\A[0-9a-f]{64}\z/)
    assert ReconciliationManifest.to_map(manifest)["decisions"] |> length() == 1
  end

  test "legacy workspace version-1 manifest normalizes and digests identically" do
    assert {:ok, manifest} = ReconciliationManifest.new(@legacy_workspace_manifest)
    assert manifest.schema_version == 1
    assert ReconciliationManifest.to_map(manifest) == @legacy_workspace_manifest

    assert {:ok, normalized} = ReconciliationManifest.normalize(@legacy_workspace_manifest)
    assert normalized == @legacy_workspace_manifest
    assert {:ok, digest} = ReconciliationManifest.digest(@legacy_workspace_manifest)
    # Pin the real golden digest once computed; first run prints it on mismatch.
    assert digest == @legacy_workspace_manifest_digest,
           "update @legacy_workspace_manifest_digest to #{inspect(digest)}"

    assert {:ok, decision_map} = ReconciliationDecision.normalize(@legacy_workspace_decision)
    assert decision_map == @legacy_workspace_decision

    assert {:ok, decision} = ReconciliationDecision.new(@legacy_workspace_decision)
    assert decision.schema_version == 1
    assert ReconciliationDecision.to_map(decision) == @legacy_workspace_decision
  end

  test "latest contracts emit version 2 while archived version 1 remains stable" do
    assert ReconciliationDecision.schema_version() == 2
    assert ReconciliationManifest.schema_version() == 2

    assert {:ok, decision} = ReconciliationDecision.new(current_retained_decision())
    assert decision.schema_version == 2

    assert {:ok, manifest} =
             ReconciliationManifest.new(
               valid_manifest([ReconciliationDecision.to_map(decision)], 1, 0, 0, 1, 0, 2)
             )

    assert ReconciliationManifest.to_map(manifest)["schema_version"] == 2
    assert hd(ReconciliationManifest.to_map(manifest)["decisions"])["schema_version"] == 2
  end

  test "version 1 rejects version-2 retained proof while version 2 admits proof and legacy audit identity" do
    proof = retained_proof()

    assert {:error, _} =
             ReconciliationDecision.new(
               @legacy_workspace_decision
               |> Map.put("resource_type", "retained_workspace_record")
               |> Map.put("resource_id", "retained-1")
               |> Map.put("expected_identity", proof)
             )

    assert {:ok, proof_decision} = ReconciliationDecision.new(current_retained_decision())
    assert proof_decision.expected_identity["identity_version"] == 2

    legacy_v2 =
      current_retained_decision()
      |> Map.put("expected_identity", retained_legacy_identity())

    assert {:ok, legacy_decision} = ReconciliationDecision.new(legacy_v2)
    refute Map.has_key?(legacy_decision.expected_identity, "identity_version")
  end

  test "manifest requires all nested decisions to match its version" do
    legacy = @legacy_workspace_decision
    current = current_retained_decision()

    assert {:error, _} =
             ReconciliationManifest.new(valid_manifest([legacy, current], 2, 2, 0, 0, 0, 1))

    assert {:error, _} =
             ReconciliationManifest.new(valid_manifest([current, legacy], 2, 2, 0, 0, 0, 2))

    assert {:ok, _} = ReconciliationManifest.new(valid_manifest([legacy], 1, 1, 0, 0, 0, 1))
    assert {:ok, _} = ReconciliationManifest.new(valid_manifest([current], 1, 0, 0, 1, 0, 2))
  end

  test "accepts closed acp_managed_session identity and mixed manifests" do
    assert {:ok, acp_decision} = ReconciliationDecision.new(valid_acp_decision())
    acp_map = ReconciliationDecision.to_map(acp_decision)

    assert acp_map["resource_type"] == "acp_managed_session"
    assert acp_map["expected_identity"]["owner_present"] == true
    assert acp_map["expected_identity"]["owner_alive"] == true
    assert acp_map["expected_identity"]["session_alive"] == true
    assert acp_map["expected_identity"]["close_cleanup_in_progress"] == false
    assert acp_map["expected_identity"]["worker_session_id"] == "acp_worker_1"

    workspace = valid_decision()
    decisions = [workspace, acp_map]

    attrs = valid_manifest(decisions, 2, 2, 0, 0, 0)
    assert {:ok, manifest} = ReconciliationManifest.new(attrs)
    assert length(ReconciliationManifest.to_map(manifest)["decisions"]) == 2

    producer_valid_text =
      valid_acp_decision()
      |> put_in(["expected_identity", "provider_session_id"], "")
      |> put_in(["expected_identity", "provider"], "")
      |> put_in(["expected_identity", "model"], "\n")
      |> put_in(["expected_identity", "status"], "\t")

    assert {:ok, _decision} = ReconciliationDecision.new(producer_valid_text)
  end

  test "rejects missing, extra, malformed, and cross-resource acp identities" do
    base = valid_acp_decision()

    missing =
      update_in(base, ["expected_identity"], &Map.delete(&1, "owner_alive"))

    assert {:error, _} = ReconciliationDecision.new(missing)

    extra =
      put_in(base, ["expected_identity", "lifecycle"], "active")

    assert {:error, _} = ReconciliationDecision.new(extra)

    malformed_boolean =
      put_in(base, ["expected_identity", "session_alive"], "yes")

    assert {:error, _} = ReconciliationDecision.new(malformed_boolean)

    mismatched_id =
      put_in(base, ["expected_identity", "resource_id"], "other-id")

    assert {:error, _} = ReconciliationDecision.new(mismatched_id)

    mismatched_task =
      put_in(base, ["expected_identity", "task_id"], "other-task")

    assert {:error, _} = ReconciliationDecision.new(mismatched_task)

    mismatched_principal =
      put_in(base, ["expected_identity", "principal_id"], "other-principal")

    assert {:error, _} = ReconciliationDecision.new(mismatched_principal)

    invalid_source_id =
      base
      |> Map.put("task_id", " task-1")
      |> put_in(["expected_identity", "task_id"], " task-1")

    assert {:error, _} = ReconciliationDecision.new(invalid_source_id)

    impossible_liveness =
      base
      |> put_in(["expected_identity", "owner_present"], false)
      |> put_in(["expected_identity", "owner_alive"], true)

    assert {:error, _} = ReconciliationDecision.new(impossible_liveness)

    impossible_close_state =
      put_in(base, ["expected_identity", "close_cleanup_in_progress"], true)

    assert {:error, _} = ReconciliationDecision.new(impossible_close_state)

    cross_workspace_on_acp =
      put_in(base, ["expected_identity", "ownership"], "owned")

    assert {:error, _} = ReconciliationDecision.new(cross_workspace_on_acp)

    workspace = valid_decision()

    cross_acp_on_workspace =
      put_in(workspace, ["expected_identity", "owner_present"], true)

    assert {:error, _} = ReconciliationDecision.new(cross_acp_on_workspace)
  end

  test "accepts closed pending_approval identity and mixed manifests" do
    assert {:ok, approval_decision} =
             ReconciliationDecision.new(valid_pending_approval_decision())

    approval_map = ReconciliationDecision.to_map(approval_decision)

    assert approval_map["resource_type"] == "pending_approval"
    assert PendingApprovalResourceId.valid?(approval_map["resource_id"])
    assert approval_map["expected_identity"]["approval_id"] == "irq_one"
    assert approval_map["expected_identity"]["source"] == "consensus"

    decisions = [valid_decision(), valid_acp_decision(), approval_map]
    attrs = valid_manifest(decisions, 3, 3, 0, 0, 0)
    assert {:ok, manifest} = ReconciliationManifest.new(attrs)
    assert length(ReconciliationManifest.to_map(manifest)["decisions"]) == 3
  end

  test "rejects pending_approval identity drift and impossible fields" do
    base = valid_pending_approval_decision()

    assert {:error, _} =
             ReconciliationDecision.new(
               put_in(base, ["expected_identity", "resource_id"], String.duplicate("a", 73))
             )

    assert {:error, _} =
             ReconciliationDecision.new(
               put_in(base, ["expected_identity", "source"], "interaction")
             )

    assert {:error, _} =
             ReconciliationDecision.new(put_in(base, ["expected_identity", "status"], "approved"))

    assert {:error, _} =
             ReconciliationDecision.new(
               put_in(base, ["expected_identity", "created_at"], "not-a-timestamp")
             )

    assert {:error, _} =
             ReconciliationDecision.new(
               put_in(base, ["expected_identity", "task_id"], "other-task")
             )

    assert {:error, _} =
             ReconciliationDecision.new(
               put_in(base, ["expected_identity", "lifecycle"], "active")
             )

    assert {:error, _} =
             ReconciliationDecision.new(
               update_in(base, ["expected_identity"], &Map.delete(&1, "approval_id"))
             )

    mixed_aliases =
      update_in(base, ["expected_identity"], fn identity ->
        Map.put(identity, :approval_id, identity["approval_id"])
      end)

    assert {:error, _} = ReconciliationDecision.new(mixed_aliases)
  end

  test "accepts known and owner-unknown Apple Container identities and binds outer lineage" do
    known = apple_container_decision()
    assert {:ok, decision} = ReconciliationDecision.new(known)

    assert ReconciliationDecision.to_map(decision)["expected_identity"] ==
             known["expected_identity"]

    unknown =
      known
      |> Map.put("task_id", nil)
      |> Map.put("principal_id", nil)
      |> Map.put("decision", "quarantine")
      |> Map.put("reason", "missing_task_or_principal_provenance")
      |> put_in(["expected_identity", "owner_status"], "unknown")
      |> put_in(["expected_identity", "validation_resource_id"], nil)
      |> put_in(["expected_identity", "workspace_id"], nil)
      |> put_in(["expected_identity", "task_id"], nil)
      |> put_in(["expected_identity", "principal_id"], nil)

    assert {:ok, _unknown_decision} = ReconciliationDecision.new(unknown)

    assert {:error, _} =
             ReconciliationDecision.new(
               put_in(known, ["expected_identity", "task_id"], "other-task")
             )

    assert AppleContainerUnitIdentity.resource_type() == "apple_container_unit"
  end

  test "admits the combined decision-source ceiling within a bounded manifest" do
    decisions =
      Enum.map(1..4_000, fn index ->
        resource_id = "lease-#{index}"

        valid_decision()
        |> Map.put("resource_id", resource_id)
        |> put_in(["expected_identity", "resource_id"], resource_id)
      end)

    assert {:ok, manifest} =
             ReconciliationManifest.new(valid_manifest(decisions, 4_000, 4_000, 0, 0, 0))

    assert length(ReconciliationManifest.to_map(manifest)["decisions"]) == 4_000
  end

  test "rejects unknown fields, malformed evidence, paths, and oversized decisions" do
    assert {:error, _} = ReconciliationDecision.new(Map.put(valid_decision(), "path", "/secret"))

    assert {:error, _} =
             ReconciliationDecision.new(Map.put(valid_decision(), "reason", "raw error"))

    invalid_identity =
      put_in(valid_decision(), ["expected_identity", "resource_id"], String.duplicate("x", 257))

    assert {:error, _} = ReconciliationDecision.new(invalid_identity)

    decision = valid_decision()
    manifest = valid_manifest([decision], 1, 0, 0, 0, 0)
    assert {:error, _} = ReconciliationManifest.new(Map.put(manifest, "authority", "operator"))

    oversized = List.duplicate(decision, 4_001)

    assert {:error, _} =
             ReconciliationManifest.new(valid_manifest(oversized, 4_001, 4_001, 0, 0, 0))
  end

  defp valid_decision, do: @legacy_workspace_decision

  defp apple_container_decision do
    suffix = String.duplicate("a", 32)

    %{
      "schema_version" => 1,
      "resource_type" => "apple_container_unit",
      "resource_id" => "acu_v1_" <> suffix,
      "task_id" => "task-1",
      "principal_id" => "principal-1",
      "decision" => "keep",
      "reason" => "live_task_owner_alive",
      "expected_identity" => %{
        "resource_type" => "apple_container_unit",
        "resource_id" => "acu_v1_" <> suffix,
        "unit_name" => "arbor-v1-" <> suffix,
        "execution_id" => "exec-1",
        "reserved_at_ms" => 100,
        "owner_status" => "known",
        "validation_resource_id" => "validation_" <> suffix,
        "workspace_id" => "ws_" <> suffix,
        "task_id" => "task-1",
        "principal_id" => "principal-1",
        "source_record_digest" => String.duplicate("b", 64)
      },
      "evidence" => %{
        "task_presence" => "observed",
        "task_state" => "running",
        "owner_status" => "live",
        "journal_status" => "complete"
      }
    }
  end

  defp valid_acp_decision do
    %{
      "schema_version" => 1,
      "resource_type" => "acp_managed_session",
      "resource_id" => "acp_worker_1",
      "task_id" => "task-1",
      "principal_id" => "principal-1",
      "decision" => "keep",
      "reason" => "live_task_owner_alive",
      "expected_identity" => %{
        "resource_type" => "acp_managed_session",
        "resource_id" => "acp_worker_1",
        "worker_session_id" => "acp_worker_1",
        "provider_session_id" => "provider-1",
        "provider" => "test",
        "model" => "model-1",
        "status" => "ready",
        "pooled" => false,
        "return_to_pool" => false,
        "task_id" => "task-1",
        "principal_id" => "principal-1",
        "owner_present" => true,
        "owner_alive" => true,
        "session_alive" => true,
        "close_cleanup_in_progress" => false
      },
      "evidence" => %{
        "task_presence" => "observed",
        "task_state" => "running",
        "owner_status" => "live",
        "journal_status" => "complete"
      }
    }
  end

  defp valid_pending_approval_decision do
    {:ok, resource_id} = PendingApprovalResourceId.resource_id("consensus", "irq_one")

    %{
      "schema_version" => 1,
      "resource_type" => "pending_approval",
      "resource_id" => resource_id,
      "task_id" => "task-1",
      "principal_id" => "principal-1",
      "decision" => "keep",
      "reason" => "live_task_owner_alive",
      "expected_identity" => %{
        "resource_type" => "pending_approval",
        "resource_id" => resource_id,
        "approval_id" => "irq_one",
        "source" => "consensus",
        "task_id" => "task-1",
        "agent_id" => "agent-1",
        "principal_id" => "principal-1",
        "approver_id" => nil,
        "resource_uri" => "arbor://fs/read/repo/file.ex",
        "action" => "read",
        "status" => "pending",
        "created_at" => "2026-07-22T12:00:00Z"
      },
      "evidence" => %{
        "task_presence" => "observed",
        "task_state" => "running",
        "owner_status" => "live",
        "journal_status" => "complete"
      }
    }
  end

  defp current_retained_decision do
    %{
      "schema_version" => ReconciliationDecision.schema_version(),
      "resource_type" => "retained_workspace_record",
      "resource_id" => "retained-1",
      "task_id" => "task-1",
      "principal_id" => "principal-1",
      "decision" => "settle",
      "reason" => "retained_expired",
      "expected_identity" => retained_proof(),
      "evidence" => %{
        "task_presence" => "observed",
        "task_state" => "done",
        "owner_status" => "dead",
        "journal_status" => "complete"
      }
    }
  end

  defp retained_legacy_identity do
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
      "expires_at" => "2026-07-22T17:00:00Z"
    }
  end

  defp retained_proof do
    retained_legacy_identity()
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

  defp valid_manifest(decisions, resources, keep, retry, settle, quarantine, version \\ 1) do
    %{
      "schema_version" => version,
      "observed_at" => "2026-07-22T17:00:00Z",
      "scope" => %{"task_id" => nil, "principal_id" => nil, "agent_id" => nil, "state" => nil},
      "observation_digest" => %{
        "task_inventory_sha256" => String.duplicate("a", 64),
        "resource_inventory_sha256" => String.duplicate("b", 64),
        "source_sha256" => String.duplicate("c", 64)
      },
      "decisions" => decisions,
      "counts" => %{
        "resources" => resources,
        "keep" => keep,
        "retry" => retry,
        "settle" => settle,
        "quarantine" => quarantine,
        "remove" => 0
      }
    }
  end
end
