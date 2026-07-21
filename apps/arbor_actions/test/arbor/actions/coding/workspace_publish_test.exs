defmodule Arbor.Actions.Coding.WorkspacePublishTest do
  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions.Coding.Workspace

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

  defp git!(path, args) do
    {output, 0} =
      System.cmd("git", ["-C", path | args],
        stderr_to_stdout: true,
        env: [{"GIT_CONFIG_NOSYSTEM", "1"}]
      )

    String.trim(output)
  end
end
