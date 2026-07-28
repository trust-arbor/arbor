defmodule Arbor.Contracts.Coding.ReconciliationManifestTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.{ReconciliationDecision, ReconciliationManifest}

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
    assert {:ok, normalized} = ReconciliationManifest.normalize(@legacy_workspace_manifest)
    assert normalized == @legacy_workspace_manifest
    assert {:ok, digest} = ReconciliationManifest.digest(@legacy_workspace_manifest)
    # Pin the real golden digest once computed; first run prints it on mismatch.
    assert digest == @legacy_workspace_manifest_digest,
           "update @legacy_workspace_manifest_digest to #{inspect(digest)}"

    assert {:ok, decision_map} = ReconciliationDecision.normalize(@legacy_workspace_decision)
    assert decision_map == @legacy_workspace_decision
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

    oversized = List.duplicate(decision, 1_001)

    assert {:error, _} =
             ReconciliationManifest.new(valid_manifest(oversized, 1_001, 1_001, 0, 0, 0))
  end

  defp valid_decision, do: @legacy_workspace_decision

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

  defp valid_manifest(decisions, resources, keep, retry, settle, quarantine) do
    %{
      "schema_version" => 1,
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
