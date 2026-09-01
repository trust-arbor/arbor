defmodule Arbor.Actions.Coding.WorkspacePublishTest do
  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Git

  @moduletag :fast

  test "publish archives the exact candidate before removing an owned worktree", %{
    tmp_dir: tmp_dir
  } do
    repo = create_git_repo(Path.join(tmp_dir, "repo"))
    branch = "test/publish-archive-remove"
    context = %{task_id: "task_publish_remove", principal_id: "agent_publish"}

    assert {:ok, lease} =
             Workspace.Acquire.run(
               %{
                 repo_path: repo,
                 branch_name: branch,
                 worktree_base_dir: Path.join(tmp_dir, "worktrees")
               },
               context
             )

    File.write!(Path.join(lease.worktree_path, "candidate.txt"), "candidate\n")
    git!(lease.worktree_path, ["add", "candidate.txt"])
    git!(lease.worktree_path, ["commit", "-m", "candidate"])
    candidate = git!(lease.worktree_path, ["rev-parse", "HEAD"])

    assert {:ok, published} =
             Workspace.Release.run(
               %{workspace_id: lease.workspace_id, mode: "publish", commit_hash: candidate},
               context
             )

    assert published.status == "removed"
    assert published.published_commit == candidate
    assert String.starts_with?(published.evidence_ref, "refs/arbor/evidence/")
    refute File.dir?(lease.worktree_path)
    assert git!(repo, ["rev-parse", published.evidence_ref]) == candidate
    assert git!(repo, ["rev-parse", "refs/heads/#{branch}"]) == candidate

    assert {:ok, replayed} =
             Workspace.Release.run(
               %{
                 workspace_id: lease.workspace_id,
                 mode: "publish",
                 commit_hash: candidate,
                 repo_path: repo
               },
               context
             )

    assert replayed.status == "already_released"
    assert replayed.published_commit == candidate
    assert replayed.evidence_ref == published.evidence_ref
  end

  test "publish replay fails closed when durable evidence is absent", %{tmp_dir: tmp_dir} do
    repo = create_git_repo(Path.join(tmp_dir, "repo"))
    candidate = git!(repo, ["rev-parse", "HEAD"])

    assert {:error, :publication_replay_unverified} =
             Workspace.Release.run(
               %{
                 workspace_id: "ws_missing_publish_receipt",
                 mode: "publish",
                 commit_hash: candidate,
                 repo_path: repo
               },
               %{task_id: "task_missing_publish_receipt", principal_id: "agent_publish"}
             )
  end

  test "publish fails closed before worktree removal when candidate does not match branch", %{
    tmp_dir: tmp_dir
  } do
    repo = create_git_repo(Path.join(tmp_dir, "repo"))
    context = %{task_id: "task_publish_mismatch", principal_id: "agent_publish"}

    assert {:ok, lease} =
             Workspace.Acquire.run(
               %{
                 repo_path: repo,
                 branch_name: "test/publish-mismatch",
                 worktree_base_dir: Path.join(tmp_dir, "worktrees")
               },
               context
             )

    File.write!(Path.join(lease.worktree_path, "candidate.txt"), "candidate\n")
    git!(lease.worktree_path, ["add", "candidate.txt"])
    git!(lease.worktree_path, ["commit", "-m", "candidate"])

    assert {:error, {:candidate_archive_failed, :branch_ref_oid_mismatch}} =
             Workspace.Release.run(
               %{
                 workspace_id: lease.workspace_id,
                 mode: "publish",
                 commit_hash: lease.base_commit
               },
               context
             )

    assert File.dir?(lease.worktree_path)

    assert {:ok, _removed} =
             Workspace.Release.run(%{workspace_id: lease.workspace_id, mode: "remove"}, context)
  end

  @tag :security_regression
  test "security regression: workspace-branch mismatch preserves review snapshot and lease evidence",
       %{tmp_dir: tmp_dir} do
    unique = System.unique_integer([:positive])
    repo = create_git_repo(Path.join(tmp_dir, "mismatch_snap_repo"))
    branch = "test/publish-mismatch-snap-#{unique}"
    context = %{task_id: "task_publish_mismatch_snap_#{unique}", principal_id: "agent_publish"}

    assert {:ok, lease} =
             Workspace.Acquire.run(
               %{
                 repo_path: repo,
                 branch_name: branch,
                 worktree_base_dir: Path.join(tmp_dir, "mismatch_snap_worktrees")
               },
               context
             )

    File.write!(Path.join(lease.worktree_path, "candidate.txt"), "candidate\n")
    git!(lease.worktree_path, ["add", "candidate.txt"])
    git!(lease.worktree_path, ["commit", "-m", "candidate"])
    candidate = git!(lease.worktree_path, ["rev-parse", "HEAD"])

    assert {:ok, snap} =
             WorkspaceLeaseRegistry.open_review_snapshot(
               lease.workspace_id,
               candidate,
               context
             )

    before = worktree_identity(lease.worktree_path)
    branch_before = git!(repo, ["rev-parse", "refs/heads/#{branch}"])
    evidence_before = evidence_refs(repo)

    assert {:error, {:candidate_archive_failed, :branch_ref_oid_mismatch}} =
             Workspace.Release.run(
               %{
                 workspace_id: lease.workspace_id,
                 mode: "publish",
                 commit_hash: lease.base_commit
               },
               context
             )

    assert {:ok, resolved} =
             WorkspaceLeaseRegistry.resolve_review_snapshot(
               snap.review_snapshot_id,
               context
             )

    assert resolved.review_snapshot_id == snap.review_snapshot_id

    assert {:ok, still} =
             WorkspaceLeaseRegistry.inspect_lease(lease.workspace_id, context)

    assert still.active == true
    assert File.dir?(lease.worktree_path)
    assert worktree_identity(lease.worktree_path) == before
    assert git!(lease.worktree_path, ["rev-parse", "HEAD"]) == candidate
    assert git!(repo, ["rev-parse", "refs/heads/#{branch}"]) == branch_before
    assert evidence_refs(repo) == evidence_before
  end

  @tag :security_regression
  test "security regression: branch mutation between preflight and archive fails closed and preserves review snapshot",
       %{tmp_dir: tmp_dir} do
    unique = System.unique_integer([:positive])
    repo = create_git_repo(Path.join(tmp_dir, "race_repo_#{unique}"))
    branch = "test/publish-race-#{unique}"
    task_id = "task_publish_race_#{unique}"
    principal_id = "agent_publish"

    archive = fn input ->
      parent = git!(input.repo_path, ["rev-parse", "#{input.settlement_tip}^"])

      git!(input.repo_path, ["update-ref", "refs/heads/#{input.branch}", parent])

      Git.archive_branch_evidence_ref(
        input.repo_path,
        input.branch,
        input.task_id,
        input.workspace_id,
        input.settlement_tip
      )
    end

    server = start_publish_registry(retained_archive: archive)

    assert {:ok, lease} =
             WorkspaceLeaseRegistry.acquire(
               %{
                 repo_path: repo,
                 branch: branch,
                 worktree_base_dir: Path.join(tmp_dir, "race_worktrees_#{unique}"),
                 task_id: task_id,
                 principal_id: principal_id
               },
               server: server
             )

    candidate_path = Path.join(lease.worktree_path, "candidate.txt")
    File.write!(candidate_path, "candidate\n")
    git!(lease.worktree_path, ["add", "candidate.txt"])
    git!(lease.worktree_path, ["commit", "-m", "candidate"])
    candidate = git!(lease.worktree_path, ["rev-parse", "HEAD"])
    parent = git!(repo, ["rev-parse", "#{candidate}^"])
    evidence_before = evidence_refs(repo)

    auth = %{
      task_id: task_id,
      principal_id: principal_id,
      server: server
    }

    assert {:ok, snap} =
             WorkspaceLeaseRegistry.open_review_snapshot(
               lease.workspace_id,
               candidate,
               auth
             )

    assert git!(lease.worktree_path, ["symbolic-ref", "HEAD"]) == "refs/heads/#{branch}"

    assert {:error, {:candidate_archive_failed, :branch_ref_oid_mismatch}} =
             WorkspaceLeaseRegistry.release(
               lease.workspace_id,
               :publish,
               Map.put(auth, :candidate_commit, candidate)
             )

    assert git!(repo, ["rev-parse", "refs/heads/#{branch}"]) == parent
    assert git!(lease.worktree_path, ["symbolic-ref", "HEAD"]) == "refs/heads/#{branch}"
    assert git!(lease.worktree_path, ["rev-parse", "HEAD"]) == parent
    assert git!(lease.worktree_path, ["rev-parse", "HEAD"]) != candidate

    assert git!(lease.worktree_path, ["rev-parse", "HEAD"]) ==
             git!(repo, ["rev-parse", "refs/heads/#{branch}"])

    assert File.dir?(lease.worktree_path)
    assert File.read!(candidate_path) == "candidate\n"
    assert git!(repo, ["cat-file", "-t", candidate]) == "commit"

    assert {:ok, still} = WorkspaceLeaseRegistry.inspect_lease(lease.workspace_id, auth)
    assert still.active == true

    assert {:ok, resolved} =
             WorkspaceLeaseRegistry.resolve_review_snapshot(
               snap.review_snapshot_id,
               auth
             )

    assert resolved.review_snapshot_id == snap.review_snapshot_id
    assert evidence_refs(repo) == evidence_before

    assert {:error, _reason} =
             Git.verify_archived_evidence_ref(
               repo,
               task_id,
               lease.workspace_id,
               candidate
             )
  end

  test "publish_retain archives the candidate and keeps the owned worktree", %{
    tmp_dir: tmp_dir
  } do
    repo = create_git_repo(Path.join(tmp_dir, "repo"))
    context = %{task_id: "task_publish_retain", principal_id: "agent_publish"}

    assert {:ok, lease} =
             Workspace.Acquire.run(
               %{
                 repo_path: repo,
                 branch_name: "test/publish-retain",
                 worktree_base_dir: Path.join(tmp_dir, "worktrees")
               },
               context
             )

    File.write!(Path.join(lease.worktree_path, "candidate.txt"), "candidate\n")
    git!(lease.worktree_path, ["add", "candidate.txt"])
    git!(lease.worktree_path, ["commit", "-m", "candidate"])
    candidate = git!(lease.worktree_path, ["rev-parse", "HEAD"])

    assert {:ok, published} =
             Workspace.Release.run(
               %{
                 workspace_id: lease.workspace_id,
                 mode: "publish_retain",
                 commit_hash: candidate
               },
               context
             )

    assert published.status == "retained"
    assert published.published_commit == candidate
    assert File.dir?(lease.worktree_path)
    assert git!(repo, ["rev-parse", published.evidence_ref]) == candidate

    assert {:ok, _removed} =
             Workspace.Release.run(%{workspace_id: lease.workspace_id, mode: "remove"}, context)
  end

  test "immutable publish verifies existing evidence and removes the still-base worktree", %{
    tmp_dir: tmp_dir
  } do
    fixture = build_immutable_publish_fixture(tmp_dir, "pub_remove")

    assert {:ok, snap} =
             WorkspaceLeaseRegistry.open_review_snapshot(
               fixture.lease.workspace_id,
               fixture.candidate_commit,
               Map.put(fixture.context, :candidate_source, "immutable_object")
             )

    assert {:ok, published} =
             WorkspaceLeaseRegistry.release(fixture.lease.workspace_id, :publish, %{
               task_id: fixture.context.task_id,
               principal_id: fixture.context.principal_id,
               candidate_commit: fixture.candidate_commit,
               candidate_source: "immutable_object"
             })

    assert published.status == "removed"
    assert published.published_commit == fixture.candidate_commit
    assert published.evidence_ref == fixture.evidence_ref
    refute File.dir?(fixture.lease.worktree_path)
    assert git!(fixture.repo, ["rev-parse", published.evidence_ref]) == fixture.candidate_commit

    assert git!(fixture.repo, ["rev-parse", "refs/heads/#{fixture.branch}"]) ==
             fixture.base_commit

    assert {:error, :not_found} =
             WorkspaceLeaseRegistry.resolve_review_snapshot(
               snap.review_snapshot_id,
               fixture.context
             )
  end

  test "immutable publish_retain keeps the still-base worktree", %{tmp_dir: tmp_dir} do
    fixture = build_immutable_publish_fixture(tmp_dir, "pub_retain")

    assert {:ok, published} =
             Workspace.Release.run(
               %{
                 workspace_id: fixture.lease.workspace_id,
                 mode: "publish_retain",
                 commit_hash: fixture.candidate_commit,
                 candidate_source: "immutable_object"
               },
               fixture.context
             )

    assert published.status == "retained"
    assert published.published_commit == fixture.candidate_commit
    assert File.dir?(fixture.lease.worktree_path)
    assert git!(fixture.lease.worktree_path, ["rev-parse", "HEAD"]) == fixture.base_commit

    assert git!(fixture.repo, ["rev-parse", "refs/heads/#{fixture.branch}"]) ==
             fixture.base_commit

    assert {:ok, _removed} =
             Workspace.Release.run(
               %{workspace_id: fixture.lease.workspace_id, mode: "remove"},
               fixture.context
             )
  end

  test "forged candidate or changed base branch fail closed before immutable cleanup", %{
    tmp_dir: tmp_dir
  } do
    forged = build_immutable_publish_fixture(tmp_dir, "pub_forged")

    assert {:error, {:candidate_evidence_unverified, :evidence_ref_oid_mismatch}} =
             WorkspaceLeaseRegistry.release(forged.lease.workspace_id, :publish, %{
               task_id: forged.context.task_id,
               principal_id: forged.context.principal_id,
               candidate_commit: forged.base_commit,
               candidate_source: "immutable_object"
             })

    assert File.dir?(forged.lease.worktree_path)
    assert git!(forged.repo, ["rev-parse", "refs/heads/#{forged.branch}"]) == forged.base_commit
    assert git!(forged.repo, ["rev-parse", forged.evidence_ref]) == forged.candidate_commit

    moved = build_immutable_publish_fixture(tmp_dir, "pub_moved")
    git!(moved.lease.worktree_path, ["commit", "--allow-empty", "-m", "move base"])

    assert {:error, :head_commit_mismatch} =
             WorkspaceLeaseRegistry.release(moved.lease.workspace_id, :publish, %{
               task_id: moved.context.task_id,
               principal_id: moved.context.principal_id,
               candidate_commit: moved.candidate_commit,
               candidate_source: "immutable_object"
             })

    assert File.dir?(moved.lease.worktree_path)
    assert git!(moved.repo, ["rev-parse", moved.evidence_ref]) == moved.candidate_commit
  end

  @tag :security_regression
  test "security regression: forged immutable publish preserves review snapshot and lease evidence",
       %{tmp_dir: tmp_dir} do
    fixture =
      build_immutable_publish_fixture(
        tmp_dir,
        "pub_snap_#{System.unique_integer([:positive])}"
      )

    opts = Map.put(fixture.context, :candidate_source, "immutable_object")
    before = worktree_identity(fixture.lease.worktree_path)
    branch_before = git!(fixture.repo, ["rev-parse", "refs/heads/#{fixture.branch}"])
    evidence_before = git!(fixture.repo, ["rev-parse", fixture.evidence_ref])

    assert {:ok, snap} =
             WorkspaceLeaseRegistry.open_review_snapshot(
               fixture.lease.workspace_id,
               fixture.candidate_commit,
               opts
             )

    assert {:error, {:candidate_evidence_unverified, :evidence_ref_oid_mismatch}} =
             WorkspaceLeaseRegistry.release(fixture.lease.workspace_id, :publish, %{
               task_id: fixture.context.task_id,
               principal_id: fixture.context.principal_id,
               candidate_commit: fixture.base_commit,
               candidate_source: "immutable_object"
             })

    assert {:ok, resolved} =
             WorkspaceLeaseRegistry.resolve_review_snapshot(
               snap.review_snapshot_id,
               fixture.context
             )

    assert resolved.review_snapshot_id == snap.review_snapshot_id
    assert worktree_identity(fixture.lease.worktree_path) == before
    assert git!(fixture.lease.worktree_path, ["rev-parse", "HEAD"]) == fixture.base_commit
    assert git!(fixture.repo, ["rev-parse", "refs/heads/#{fixture.branch}"]) == branch_before
    assert git!(fixture.repo, ["rev-parse", fixture.evidence_ref]) == evidence_before
    assert File.dir?(fixture.lease.worktree_path)
  end

  test "release/3 and Workspace.Release reject mixed and unknown candidate_source before collapse",
       %{tmp_dir: tmp_dir} do
    fixture = build_immutable_publish_fixture(tmp_dir, "pub_src")

    mixed =
      %{
        task_id: fixture.context.task_id,
        principal_id: fixture.context.principal_id,
        candidate_commit: fixture.candidate_commit,
        candidate_source: "immutable_object"
      }
      |> Map.put("candidate_source", "immutable_object")

    assert {:error, :ambiguous_candidate_source} =
             WorkspaceLeaseRegistry.release(fixture.lease.workspace_id, :publish, mixed)

    assert {:error, :invalid_candidate_source} =
             WorkspaceLeaseRegistry.release(fixture.lease.workspace_id, :publish, %{
               task_id: fixture.context.task_id,
               principal_id: fixture.context.principal_id,
               candidate_commit: fixture.candidate_commit,
               candidate_source: "immutable"
             })

    assert File.dir?(fixture.lease.worktree_path)
    assert git!(fixture.repo, ["rev-parse", fixture.evidence_ref]) == fixture.candidate_commit

    assert {:error, :invalid_candidate_source} =
             Workspace.Release.run(
               %{
                 workspace_id: fixture.lease.workspace_id,
                 mode: "publish",
                 commit_hash: fixture.candidate_commit,
                 candidate_source: "immutable"
               },
               fixture.context
             )

    assert {:error, :ambiguous_candidate_source} =
             Workspace.Release.run(
               %{
                 workspace_id: fixture.lease.workspace_id,
                 mode: "publish",
                 commit_hash: fixture.candidate_commit,
                 candidate_source: "immutable_object"
               }
               |> Map.put("candidate_source", "immutable_object"),
               fixture.context
             )

    assert File.dir?(fixture.lease.worktree_path)
  end

  test "Workspace.Release forwards immutable_object and replay admits source before evidence", %{
    tmp_dir: tmp_dir
  } do
    fixture = build_immutable_publish_fixture(tmp_dir, "pub_fwd")

    assert {:ok, published} =
             Workspace.Release.run(
               %{
                 workspace_id: fixture.lease.workspace_id,
                 mode: "publish",
                 commit_hash: fixture.candidate_commit,
                 candidate_source: "immutable_object"
               },
               fixture.context
             )

    assert published.status == "removed"
    assert published.evidence_ref == fixture.evidence_ref
    refute File.dir?(fixture.lease.worktree_path)

    assert {:ok, replayed} =
             Workspace.Release.run(
               %{
                 workspace_id: fixture.lease.workspace_id,
                 mode: "publish",
                 commit_hash: fixture.candidate_commit,
                 candidate_source: "immutable_object",
                 repo_path: fixture.repo
               },
               fixture.context
             )

    assert replayed.status == "already_released"
    assert replayed.evidence_ref == published.evidence_ref

    assert {:ok, absent_replay} =
             Workspace.Release.run(
               %{
                 workspace_id: fixture.lease.workspace_id,
                 mode: "publish",
                 commit_hash: fixture.candidate_commit,
                 repo_path: fixture.repo
               },
               fixture.context
             )

    assert absent_replay.status == "already_released"
    assert absent_replay.evidence_ref == published.evidence_ref

    assert {:error, :invalid_candidate_source} =
             Workspace.Release.run(
               %{
                 workspace_id: fixture.lease.workspace_id,
                 mode: "publish",
                 commit_hash: fixture.candidate_commit,
                 candidate_source: "immutable",
                 repo_path: fixture.repo
               },
               fixture.context
             )

    assert {:error, :ambiguous_candidate_source} =
             Workspace.Release.run(
               %{
                 workspace_id: fixture.lease.workspace_id,
                 mode: "publish",
                 commit_hash: fixture.candidate_commit,
                 candidate_source: "immutable_object",
                 repo_path: fixture.repo
               }
               |> Map.put("candidate_source", "workspace_branch"),
               fixture.context
             )

    assert {:error, :ambiguous_candidate_source} =
             WorkspaceLeaseRegistry.release(
               fixture.lease.workspace_id,
               :publish,
               %{
                 task_id: fixture.context.task_id,
                 principal_id: fixture.context.principal_id,
                 candidate_commit: fixture.candidate_commit,
                 repo_path: fixture.repo,
                 candidate_source: "immutable_object"
               }
               |> Map.put("candidate_source", "immutable_object")
             )

    assert git!(fixture.repo, ["rev-parse", published.evidence_ref]) == fixture.candidate_commit
  end

  test "immutable_object does not upgrade a branch-backed shape and workspace_branch does not upgrade a base worktree",
       %{tmp_dir: tmp_dir} do
    branch_backed = build_branch_publish_shape(tmp_dir)

    assert {:error, :head_commit_mismatch} =
             WorkspaceLeaseRegistry.release(branch_backed.lease.workspace_id, :publish, %{
               task_id: branch_backed.context.task_id,
               principal_id: branch_backed.context.principal_id,
               candidate_commit: branch_backed.candidate_commit,
               candidate_source: "immutable_object"
             })

    assert File.dir?(branch_backed.lease.worktree_path)

    fixture = build_immutable_publish_fixture(tmp_dir, "no_upgrade")

    assert {:error, {:candidate_archive_failed, :branch_ref_oid_mismatch}} =
             Workspace.Release.run(
               %{
                 workspace_id: fixture.lease.workspace_id,
                 mode: "publish",
                 commit_hash: fixture.candidate_commit
               },
               fixture.context
             )

    assert File.dir?(fixture.lease.worktree_path)

    assert git!(fixture.repo, ["rev-parse", "refs/heads/#{fixture.branch}"]) ==
             fixture.base_commit
  end

  defp build_immutable_publish_fixture(tmp_dir, prefix) do
    repo = create_git_repo(Path.join(tmp_dir, "#{prefix}_repo"))
    branch = "test/#{prefix}-#{System.unique_integer([:positive])}"
    context = %{task_id: "task_#{prefix}", principal_id: "agent_publish"}

    assert {:ok, lease} =
             Workspace.Acquire.run(
               %{
                 repo_path: repo,
                 branch_name: branch,
                 worktree_base_dir: Path.join(tmp_dir, "#{prefix}_worktrees")
               },
               context
             )

    {candidate_commit, _tree} =
      object_commit(repo, lease.base_commit, "candidate.txt", "candidate\n", tmp_dir)

    assert {:ok, %{hidden_ref: evidence_ref}} =
             Git.pin_task_workspace_commit(
               repo,
               context.task_id,
               lease.workspace_id,
               candidate_commit
             )

    %{
      repo: repo,
      branch: branch,
      context: context,
      lease: lease,
      base_commit: lease.base_commit,
      candidate_commit: candidate_commit,
      evidence_ref: evidence_ref
    }
  end

  defp build_branch_publish_shape(tmp_dir) do
    repo = create_git_repo(Path.join(tmp_dir, "branch_shape_repo"))
    context = %{task_id: "task_branch_shape", principal_id: "agent_publish"}

    assert {:ok, lease} =
             Workspace.Acquire.run(
               %{
                 repo_path: repo,
                 branch_name: "test/branch-shape-#{System.unique_integer([:positive])}",
                 worktree_base_dir: Path.join(tmp_dir, "branch_shape_worktrees")
               },
               context
             )

    File.write!(Path.join(lease.worktree_path, "candidate.txt"), "candidate\n")
    git!(lease.worktree_path, ["add", "candidate.txt"])
    git!(lease.worktree_path, ["commit", "-m", "candidate"])
    candidate_commit = git!(lease.worktree_path, ["rev-parse", "HEAD"])

    %{lease: lease, context: context, candidate_commit: candidate_commit}
  end

  defp object_commit(repo, parent, path, content, tmp_dir) do
    blob_file = Path.join(tmp_dir, "blob-#{System.unique_integer([:positive])}")
    File.write!(blob_file, content)
    blob = git!(repo, ["hash-object", "-w", blob_file])
    index = Path.join(tmp_dir, "index-#{System.unique_integer([:positive])}")
    git_index!(repo, index, ["read-tree", parent])

    git_index!(repo, index, [
      "update-index",
      "--add",
      "--cacheinfo",
      "100644,#{blob},#{path}"
    ])

    tree = git_index!(repo, index, ["write-tree"])
    File.rm(index)
    commit = git!(repo, ["commit-tree", tree, "-p", parent, "-m", "object candidate"])
    {commit, tree}
  end

  defp worktree_identity(worktree) do
    %{
      head: git!(worktree, ["rev-parse", "HEAD"]),
      branch: git!(worktree, ["rev-parse", "--abbrev-ref", "HEAD"]),
      status: git!(worktree, ["status", "--porcelain", "-z"]),
      index: git!(worktree, ["write-tree"])
    }
  end

  defp evidence_refs(repo) do
    git!(repo, ["for-each-ref", "--format=%(refname) %(objectname)", "refs/arbor/evidence"])
  end

  defp start_publish_registry(opts) do
    server = :"ws_publish_#{System.unique_integer([:positive])}"

    start_supervised!(
      {WorkspaceLeaseRegistry,
       [
         name: server,
         retention_journal: :disabled,
         linux_dependency_baseline_materializer:
           Arbor.Actions.TestLinuxBaselineMaterializer,
         retained_archive: Keyword.fetch!(opts, :retained_archive)
       ]},
      id: server
    )

    server
  end

  defp git_index!(repo, index, args) do
    {output, 0} =
      System.cmd("git", ["-C", repo | args],
        stderr_to_stdout: true,
        env: [{"GIT_INDEX_FILE", index}]
      )

    String.trim(output)
  end

  defp git!(path, args) do
    {output, 0} =
      System.cmd("git", ["-C", path | args],
        stderr_to_stdout: true,
        env: [{"GIT_CONFIG_NOSYSTEM", "1"}]
      )

    String.trim(output)
  end
end
