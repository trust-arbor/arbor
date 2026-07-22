defmodule Arbor.Orchestrator.CodingPlan.ReconciliationArtifactStoreTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Arbor.Contracts.Coding.ReconciliationManifest
  alias Arbor.Orchestrator.CodingPlan.ArtifactStore

  @moduletag :fast

  test "persists an immutable digest-addressed envelope with round-trip verification" do
    root =
      Path.join(
        System.tmp_dir!(),
        "reconciliation_artifact_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)

    manifest = manifest()
    {:ok, digest} = ReconciliationManifest.digest(manifest)

    envelope = %{
      "schema_version" => 1,
      "manifest" => manifest,
      "manifest_sha256" => digest,
      "persisted_at" => "2026-07-22T17:00:01Z",
      "supplementary_evidence" => %{"acp_sessions" => %{"counts" => %{"observed" => 0}}}
    }

    assert {:ok, descriptor} =
             ArtifactStore.archive_reconciliation_manifest(root, manifest["scope"], envelope)

    assert descriptor["manifest_sha256"] == digest

    assert descriptor["envelope_sha256"] ==
             :crypto.hash(:sha256, File.read!(descriptor["reconciliation_manifest_path"]))
             |> Base.encode16(case: :lower)

    assert descriptor["reconciliation_manifest_path"] =~ "scope-"
    refute descriptor["reconciliation_manifest_path"] =~ "task-1"
    assert Arbor.Common.SafePath.within?(descriptor["reconciliation_manifest_path"], root)

    assert {:ok, stat} = File.stat(descriptor["reconciliation_manifest_path"])
    assert (stat.mode &&& 0o777) == 0o600

    assert {:ok, round_trip} =
             ArtifactStore.read_reconciliation_manifest(root, manifest["scope"], digest)

    assert round_trip["manifest_sha256"] == digest

    assert {:ok, ^round_trip} =
             ArtifactStore.read_reconciliation_manifest(
               root,
               manifest["scope"],
               digest,
               descriptor["envelope_sha256"]
             )

    assert {:error, :reconciliation_manifest_verification_failed} =
             ArtifactStore.read_reconciliation_manifest(
               root,
               manifest["scope"],
               digest,
               String.duplicate("0", 64)
             )

    assert {:ok, ^descriptor} =
             ArtifactStore.archive_reconciliation_manifest(root, manifest["scope"], envelope)

    conflicting = Map.put(envelope, "persisted_at", "2026-07-22T17:00:02Z")

    assert {:error, :reconciliation_manifest_conflict} =
             ArtifactStore.archive_reconciliation_manifest(root, manifest["scope"], conflicting)
  end

  test "same manifest with different envelope metadata is an immutable conflict" do
    root =
      Path.join(
        System.tmp_dir!(),
        "reconciliation_artifact_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    manifest = manifest()
    {:ok, digest} = ReconciliationManifest.digest(manifest)

    envelope = %{
      "schema_version" => 1,
      "manifest" => manifest,
      "manifest_sha256" => digest,
      "persisted_at" => "2026-07-22T17:00:01Z",
      "supplementary_evidence" => %{"acp_sessions" => %{"counts" => %{"observed" => 0}}}
    }

    assert {:ok, first} =
             ArtifactStore.archive_reconciliation_manifest(root, manifest["scope"], envelope)

    changed = Map.put(envelope, "supplementary_evidence", %{"acp_sessions" => %{"observed" => 1}})

    assert {:error, :reconciliation_manifest_conflict} =
             ArtifactStore.archive_reconciliation_manifest(root, manifest["scope"], changed)

    assert first["manifest_sha256"] == digest

    refute first["envelope_sha256"] ==
             :crypto.hash(:sha256, Jason.encode!(changed)) |> Base.encode16(case: :lower)
  end

  test "rejects symlinked reconciliation directories and files" do
    root =
      Path.join(
        System.tmp_dir!(),
        "reconciliation_artifact_#{System.unique_integer([:positive])}"
      )

    outside =
      Path.join(
        System.tmp_dir!(),
        "reconciliation_artifact_outside_#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(outside)
    end)

    manifest = manifest()
    {:ok, digest} = ReconciliationManifest.digest(manifest)
    envelope = envelope(manifest, digest)

    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(root, "coding-reconciliation"))

    assert {:error, :reconciliation_manifest_symlink} =
             ArtifactStore.archive_reconciliation_manifest(root, manifest["scope"], envelope)

    File.rm_rf!(root)

    assert {:ok, descriptor} =
             ArtifactStore.archive_reconciliation_manifest(root, manifest["scope"], envelope)

    outside_file = Path.join(outside, "outside.json")
    File.write!(outside_file, "outside")
    File.rm!(descriptor["reconciliation_manifest_path"])
    File.ln_s!(outside_file, descriptor["reconciliation_manifest_path"])

    assert {:error, :reconciliation_manifest_symlink} =
             ArtifactStore.archive_reconciliation_manifest(root, manifest["scope"], envelope)
  end

  test "rejects a forged manifest digest before writing" do
    root =
      Path.join(
        System.tmp_dir!(),
        "reconciliation_artifact_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    manifest = manifest()

    assert {:error, :reconciliation_manifest_digest_mismatch} =
             ArtifactStore.archive_reconciliation_manifest(
               root,
               manifest["scope"],
               %{
                 "schema_version" => 1,
                 "manifest" => manifest,
                 "manifest_sha256" => String.duplicate("0", 64),
                 "persisted_at" => "2026-07-22T17:00:01Z",
                 "supplementary_evidence" => %{}
               }
             )

    refute File.exists?(root)
  end

  defp manifest do
    %{
      "schema_version" => 1,
      "observed_at" => "2026-07-22T17:00:00Z",
      "scope" => %{
        "task_id" => "task-1",
        "principal_id" => "principal-1",
        "agent_id" => nil,
        "state" => nil
      },
      "observation_digest" => %{
        "task_inventory_sha256" => String.duplicate("1", 64),
        "resource_inventory_sha256" => String.duplicate("2", 64),
        "source_sha256" => String.duplicate("3", 64)
      },
      "decisions" => [],
      "counts" => %{
        "resources" => 0,
        "keep" => 0,
        "retry" => 0,
        "settle" => 0,
        "quarantine" => 0,
        "remove" => 0
      }
    }
  end

  defp envelope(manifest, digest) do
    %{
      "schema_version" => 1,
      "manifest" => manifest,
      "manifest_sha256" => digest,
      "persisted_at" => "2026-07-22T17:00:01Z",
      "supplementary_evidence" => %{}
    }
  end
end
