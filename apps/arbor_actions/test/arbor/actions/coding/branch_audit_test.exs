defmodule Arbor.Actions.Coding.BranchAuditTest do
  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions
  alias Arbor.Actions.Coding.BranchAuditCore, as: Core
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry

  @moduletag :fast

  test "dry-run is deterministic and changes no local or hidden refs", %{tmp_dir: tmp_dir} do
    repo = build_fixture(Path.join(tmp_dir, "repo"))
    before = refs(repo)

    assert {:ok, first} = Actions.audit_coding_branches(repo, "main")
    assert {:ok, second} = Actions.audit_coding_branches(repo, "main")

    assert first["manifest_sha256"] == second["manifest_sha256"]
    assert refs(repo) == before
    assert Enum.any?(first["branches"], &(&1["class"] == "merged"))
    assert Enum.any?(first["branches"], &(&1["class"] == "patch_equivalent"))
    assert Enum.any?(first["branches"], &(&1["class"] == "unique" and &1["action"] == "preserve"))
  end

  test "protected, checked-out, and retained refs survive the audit", %{tmp_dir: tmp_dir} do
    repo = build_fixture(Path.join(tmp_dir, "repo"))
    branch = "workspace/retained-audit"
    worktree_base = Path.join(tmp_dir, "worktrees")

    assert {:ok, lease} =
             WorkspaceLeaseRegistry.acquire(%{
               repo_path: repo,
               branch: branch,
               worktree_base_dir: worktree_base,
               task_id: "audit-retained-task",
               principal_id: "audit-retained-principal"
             })

    assert {:ok, _retained} = WorkspaceLeaseRegistry.release(lease.workspace_id, :retain)

    on_exit(fn ->
      _ =
        WorkspaceLeaseRegistry.release(lease.workspace_id, :remove,
          task_id: "audit-retained-task",
          principal_id: "audit-retained-principal"
        )
    end)

    assert {:ok, manifest} = Actions.audit_coding_branches(repo, "main")

    for ref <- [
          "refs/heads/main",
          "refs/heads/preserve/keep",
          "refs/heads/checked-out",
          "refs/heads/#{branch}"
        ] do
      entry = Enum.find(manifest["branches"], &(&1["ref"] == ref))
      assert entry["action"] == "preserve"
      assert entry["class"] in ["destination", "explicitly_preserved", "checked_out", "retained"]
    end
  end

  test "digest and destination drift fail closed before any effect", %{tmp_dir: tmp_dir} do
    repo = build_fixture(Path.join(tmp_dir, "repo"))
    assert {:ok, manifest} = Actions.audit_coding_branches(repo, "main")
    before = refs(repo)

    assert {:error, :reviewed_branch_audit_drift} =
             Actions.settle_coding_branches(manifest, String.duplicate("0", 64))

    refute refs(repo) == []
    assert refs(repo) == before

    add_commit(repo, "destination-drift.txt", "destination drift\n", "destination drift")

    assert {:error, :destination_drift} =
             Actions.settle_coding_branches(manifest, manifest["manifest_sha256"])

    assert refs(repo) != []
  end

  test "security regression: recomputed unsafe retirement manifests have no effect", %{
    tmp_dir: tmp_dir
  } do
    repo = build_fixture(Path.join(tmp_dir, "repo"))
    assert {:ok, manifest} = Actions.audit_coding_branches(repo, "main")
    before = refs(repo)

    unique_retirement =
      update_branch(manifest, "refs/heads/unique", &Map.put(&1, "action", "archive_and_retire"))

    candidate_mismatch =
      update_branch(manifest, "refs/heads/merged", fn entry ->
        put_in(entry, ["proof", "candidate_commit"], String.duplicate("a", 40))
      end)

    destination_mismatch =
      update_branch(manifest, "refs/heads/merged", fn entry ->
        put_in(entry, ["proof", "destination_ref"], "refs/heads/other")
      end)

    destination_oid_mismatch =
      update_branch(manifest, "refs/heads/merged", fn entry ->
        put_in(entry, ["proof", "destination_commit"], String.duplicate("a", 40))
      end)

    entry_oid_mismatch =
      update_branch(manifest, "refs/heads/merged", fn entry ->
        Map.put(entry, "oid", String.duplicate("a", 40))
      end)

    for tampered <- [
          unique_retirement,
          candidate_mismatch,
          destination_mismatch,
          destination_oid_mismatch,
          entry_oid_mismatch
        ] do
      reviewed = resign(tampered)

      assert {:error, _reason} =
               Actions.settle_coding_branches(reviewed, reviewed["manifest_sha256"])
    end

    assert refs(repo) == before
  end

  test "archive precedes retirement and absent branch without evidence is residue", %{
    tmp_dir: tmp_dir
  } do
    repo = build_fixture(Path.join(tmp_dir, "repo"))
    assert {:ok, manifest} = Actions.audit_coding_branches(repo, "main")
    retire = Enum.find(manifest["branches"], &(&1["ref"] == "refs/heads/merged"))
    assert retire["action"] == "archive_and_retire"

    delete_branch(repo, "merged")

    assert {:ok, report} = Actions.settle_coding_branches(manifest, manifest["manifest_sha256"])
    result = Enum.find(report["entries"], &(&1["ref"] == "refs/heads/merged"))
    assert result["status"] == "preserved"
    assert result["reason"] == "branch_absent_without_matching_evidence"
  end

  test "CAS race preserves the branch after exact-tip archive", %{tmp_dir: tmp_dir} do
    repo = build_fixture(Path.join(tmp_dir, "repo"))
    assert {:ok, manifest} = Actions.audit_coding_branches(repo, "main")
    retire = Enum.find(manifest["branches"], &(&1["ref"] == "refs/heads/merged"))
    replacement = git!(repo, ["rev-parse", "main"])

    Process.put(
      {Arbor.Actions.Git, :pre_delete_branch_ref_hook},
      fn _repo, branch ->
        {_, 0} = System.cmd("git", ["update-ref", "refs/heads/#{branch}", replacement], cd: repo)
      end
    )

    assert {:ok, report} = Actions.settle_coding_branches(manifest, manifest["manifest_sha256"])
    result = Enum.find(report["entries"], &(&1["ref"] == retire["ref"]))
    assert result["status"] == "preserved"
    assert git!(repo, ["rev-parse", "refs/heads/merged"]) == replacement

    assert Enum.any?(
             git!(repo, ["for-each-ref", "--format=%(refname)", "refs/arbor/evidence"])
             |> String.split("\n", trim: true),
             &String.contains?(&1, "refs/arbor/evidence/")
           )
  end

  test "same branch at a new reviewed OID receives distinct replay-stable evidence", %{
    tmp_dir: tmp_dir
  } do
    repo = build_fixture(Path.join(tmp_dir, "repo"))
    assert {:ok, first_manifest} = Actions.audit_coding_branches(repo, "main")
    first_entry = Enum.find(first_manifest["branches"], &(&1["ref"] == "refs/heads/merged"))

    assert {:ok, first_report} =
             Actions.settle_coding_branches(first_manifest, first_manifest["manifest_sha256"])

    assert Enum.find(first_report["entries"], &(&1["ref"] == first_entry["ref"]))["status"] ==
             "settled"

    first_evidence = evidence_refs(repo)
    add_commit(repo, "new-destination.txt", "new destination\n", "new destination")
    new_oid = git!(repo, ["rev-parse", "main"])
    refute new_oid == first_entry["oid"]
    git!(repo, ["branch", "merged", new_oid])

    assert {:ok, second_manifest} = Actions.audit_coding_branches(repo, "main")
    second_entry = Enum.find(second_manifest["branches"], &(&1["ref"] == first_entry["ref"]))
    assert second_entry["oid"] == new_oid
    assert second_entry["action"] == "archive_and_retire"

    assert {:ok, second_report} =
             Actions.settle_coding_branches(second_manifest, second_manifest["manifest_sha256"])

    assert Enum.find(second_report["entries"], &(&1["ref"] == second_entry["ref"]))["status"] ==
             "settled"

    second_evidence = evidence_refs(repo)
    assert length(second_evidence) == length(first_evidence) + 1
    assert Enum.all?(first_evidence, &(&1 in second_evidence))
  end

  test "read-only retention snapshot does not clean expired evidence", %{tmp_dir: tmp_dir} do
    repo = build_fixture(Path.join(tmp_dir, "repo"))
    parent = Path.join(tmp_dir, "arbor-home")
    journal = Path.join(parent, "retention")
    File.mkdir_p!(parent)
    File.chmod!(parent, 0o755)
    File.mkdir_p!(journal)
    File.chmod!(journal, 0o700)
    git!(repo, ["branch", "retained/expired"])
    marker = retention_marker(repo)
    {:ok, encoded} = Arbor.Actions.Coding.WorkspaceRetentionJournalCore.encode_record(marker)
    {:ok, json} = Jason.encode(encoded)
    path = Path.join(journal, "retained:expired-audit-marker.json")
    File.write!(path, json)
    File.chmod!(path, 0o600)

    before = File.read!(path)
    before_refs = refs(repo)

    assert {:ok, manifest} =
             Actions.audit_coding_branches(repo, "main",
               registry_server: :missing,
               journal_path: journal
             )

    entry = Enum.find(manifest["branches"], &(&1["ref"] == "refs/heads/retained/expired"))
    assert entry["class"] == "retained"
    assert entry["action"] == "preserve"
    assert refs(repo) == before_refs

    assert File.exists?(path)
    assert File.read!(path) == before
    assert File.dir?(Path.join(tmp_dir, "worktrees")) == false
  end

  test "read-only retention snapshot rejects a group-writable parent", %{tmp_dir: tmp_dir} do
    repo = build_fixture(Path.join(tmp_dir, "repo"))
    parent = Path.join(tmp_dir, "writable-arbor-home")
    journal = Path.join(parent, "retention")
    File.mkdir_p!(journal)
    File.chmod!(journal, 0o700)
    File.chmod!(parent, 0o775)
    on_exit(fn -> File.chmod(parent, 0o700) end)
    before = refs(repo)

    assert {:error, {:retention_inventory_unavailable, :retention_inventory_parent_permissions}} =
             Actions.audit_coding_branches(repo, "main",
               registry_server: :missing,
               journal_path: journal
             )

    assert refs(repo) == before
  end

  test "invalid durable branch name poisons the read-only audit", %{tmp_dir: tmp_dir} do
    repo = build_fixture(Path.join(tmp_dir, "repo"))
    parent = Path.join(tmp_dir, "invalid-branch-arbor-home")
    journal = Path.join(parent, "retention")
    File.mkdir_p!(parent)
    File.chmod!(parent, 0o755)
    File.mkdir_p!(journal)
    File.chmod!(journal, 0o700)

    marker =
      retention_marker(repo)
      |> Map.put(:workspace_id, "invalid-branch-marker")
      |> Map.put(:branch, "invalid~branch")
      |> put_in([:worktree_registration, :branch], "invalid~branch")

    {:ok, encoded} = Arbor.Actions.Coding.WorkspaceRetentionJournalCore.encode_record(marker)
    {:ok, json} = Jason.encode(encoded)
    path = Path.join(journal, "retained:invalid-branch-marker.json")
    File.write!(path, json)
    File.chmod!(path, 0o600)
    before = refs(repo)

    assert {:error, :invalid_retention_branch} =
             Actions.audit_coding_branches(repo, "main",
               registry_server: :missing,
               journal_path: journal
             )

    assert refs(repo) == before
    assert File.read!(path) == json
  end

  defp build_fixture(repo) do
    create_git_repo(repo)
    git!(repo, ["branch", "-m", "main"])
    initial = git!(repo, ["rev-parse", "HEAD"])
    git!(repo, ["branch", "preserve/keep"])

    git!(repo, ["checkout", "-b", "merged"])
    add_commit(repo, "merged.txt", "merged\n", "merged")
    git!(repo, ["checkout", "main"])
    git!(repo, ["merge", "--ff-only", "merged"])

    git!(repo, ["checkout", "-b", "patch-equivalent", initial])
    add_commit(repo, "patch.txt", "patch\n", "patch candidate")
    git!(repo, ["checkout", "main"])
    git!(repo, ["cherry-pick", "patch-equivalent"])

    git!(repo, ["checkout", "-b", "unique", initial])
    add_commit(repo, "unique.txt", "unique\n", "unique")
    git!(repo, ["checkout", "main"])
    git!(repo, ["branch", "checked-out", initial])
    checked_path = Path.join(Path.dirname(repo), "checked-worktree")
    git!(repo, ["worktree", "add", checked_path, "checked-out"])
    repo
  end

  defp retention_marker(repo) do
    %{
      workspace_id: "expired-audit-marker",
      task_id: nil,
      principal_id: nil,
      repo_path: repo,
      worktree_path: Path.join(System.tmp_dir!(), "expired-audit-worktree"),
      display_worktree_path: Path.join(System.tmp_dir!(), "expired-audit-worktree"),
      branch: "retained/expired",
      base_commit: git!(repo, ["rev-parse", "HEAD"]),
      ownership: :owned,
      lifecycle: "retained",
      runtime_id: "audit-runtime",
      lstat_identity: %{type: :directory, major_device: 0, minor_device: 0, inode: 1},
      worktree_registration: %{
        path: Path.join(System.tmp_dir!(), "expired-audit-worktree"),
        head: git!(repo, ["rev-parse", "HEAD"]),
        branch: "retained/expired"
      },
      expires_at: DateTime.add(DateTime.utc_now(), -60, :second),
      retry_count: 8,
      branch_provenance: "unknown"
    }
  end

  defp add_commit(repo, file, content, message) do
    File.write!(Path.join(repo, file), content)
    git!(repo, ["add", file])
    git!(repo, ["commit", "-m", message])
  end

  defp delete_branch(repo, branch), do: git!(repo, ["update-ref", "-d", "refs/heads/#{branch}"])

  defp update_branch(manifest, ref, update) do
    Map.update!(manifest, "branches", fn branches ->
      Enum.map(branches, fn entry -> if entry["ref"] == ref, do: update.(entry), else: entry end)
    end)
  end

  defp resign(manifest), do: Map.put(manifest, "manifest_sha256", Core.digest(manifest))

  defp evidence_refs(repo) do
    repo
    |> git!(["for-each-ref", "--format=%(refname)", "refs/arbor/evidence"])
    |> String.split("\n", trim: true)
  end

  defp refs(repo), do: git!(repo, ["show-ref"])

  defp git!(repo, args) do
    {output, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    String.trim(output)
  end
end
