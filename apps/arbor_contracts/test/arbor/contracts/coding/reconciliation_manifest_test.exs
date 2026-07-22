defmodule Arbor.Contracts.Coding.ReconciliationManifestTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.{ReconciliationDecision, ReconciliationManifest}

  @moduletag :fast

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

  defp valid_decision do
    %{
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
