defmodule Arbor.Actions.Coding.AdoptionTest do
  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions.Coding.Adoption
  alias Arbor.Actions.Coding.Workspace

  @moduletag :fast
  @moduletag :security_regression

  test "adoption archives proof first and retires an exact invocation-created branch", %{
    tmp_dir: tmp_dir
  } do
    fixture = published_candidate(tmp_dir, "created", "publish")
    git!(fixture.repo, ["update-ref", fixture.destination_ref, fixture.candidate_commit])

    assert {:ok, proof} = Adoption.prove(fixture.candidate, fixture.destination_ref)

    assert {:ok, settlement} = Adoption.settle(fixture.candidate, proof)
    assert settlement["status"] == "adopted"
    assert settlement["branch_retired"] == true

    assert git!(fixture.repo, ["rev-parse", fixture.candidate["evidence_ref"]]) ==
             fixture.candidate_commit

    refute branch_exists?(fixture.repo, fixture.branch)

    # Archive and branch retirement are both replay-safe.
    assert {:ok, replay} = Adoption.settle(fixture.candidate, proof)
    assert replay["branch_retired"] == true
  end

  test "security regression: a candidate branch whose tip moved is preserved", %{
    tmp_dir: tmp_dir
  } do
    fixture = published_candidate(tmp_dir, "created", "publish")
    git!(fixture.repo, ["update-ref", fixture.destination_ref, fixture.candidate_commit])
    moved_tip = commit_tree(fixture.repo, fixture.candidate_commit, "moved branch")
    git!(fixture.repo, ["update-ref", "refs/heads/#{fixture.branch}", moved_tip])

    assert {:ok, proof} = Adoption.prove(fixture.candidate, fixture.destination_ref)
    assert {:ok, settlement} = Adoption.settle(fixture.candidate, proof)

    assert settlement["branch_retired"] == false
    assert settlement["branch_preserved_reason"] == "branch_tip_changed"
    assert git!(fixture.repo, ["rev-parse", "refs/heads/#{fixture.branch}"]) == moved_tip
  end

  test "security regression: reused branch provenance is never deletion authority", %{
    tmp_dir: tmp_dir
  } do
    fixture = published_candidate(tmp_dir, "reused", "publish_retain")
    git!(fixture.repo, ["update-ref", fixture.destination_ref, fixture.candidate_commit])

    assert File.dir?(fixture.worktree_path)
    assert {:ok, proof} = Adoption.prove(fixture.candidate, fixture.destination_ref)
    assert {:ok, settlement} = Adoption.settle(fixture.candidate, proof)

    assert settlement["branch_retired"] == false
    assert settlement["branch_preserved_reason"] == "reused_branch"
    refute File.dir?(fixture.worktree_path)
    assert branch_exists?(fixture.repo, fixture.branch)
  end

  test "security regression: candidate and internal evidence refs cannot prove adoption", %{
    tmp_dir: tmp_dir
  } do
    fixture = published_candidate(tmp_dir, "created", "publish")

    assert {:error, :candidate_branch_is_not_an_adoption_destination} =
             Adoption.prove(fixture.candidate, fixture.branch)

    assert {:error, :candidate_branch_is_not_an_adoption_destination} =
             Adoption.prove(fixture.candidate, "refs/heads/#{fixture.branch}")

    assert {:error, :candidate_evidence_is_not_an_adoption_destination} =
             Adoption.prove(fixture.candidate, fixture.candidate["evidence_ref"])

    internal_ref = "refs/arbor/other/#{System.unique_integer([:positive])}"
    git!(fixture.repo, ["update-ref", internal_ref, fixture.candidate_commit])

    assert {:error, :arbor_internal_ref_is_not_an_adoption_destination} =
             Adoption.prove(fixture.candidate, internal_ref)

    assert branch_exists?(fixture.repo, fixture.branch)
  end

  defp published_candidate(tmp_dir, provenance, mode) do
    repo = create_git_repo(Path.join(tmp_dir, "repo"))
    destination_ref = git!(repo, ["symbolic-ref", "HEAD"])
    branch = "test/adoption-#{provenance}-#{System.unique_integer([:positive])}"
    context = %{task_id: "task_adoption_#{provenance}", principal_id: "agent_adoption"}

    if provenance == "reused", do: git!(repo, ["branch", branch])

    assert {:ok, lease} =
             Workspace.Acquire.run(
               %{
                 repo_path: repo,
                 branch_name: branch,
                 worktree_base_dir: Path.join(tmp_dir, "worktrees")
               },
               context
             )

    assert lease.branch_provenance == provenance
    File.write!(Path.join(lease.worktree_path, "candidate.txt"), "candidate\n")
    git!(lease.worktree_path, ["add", "candidate.txt"])
    git!(lease.worktree_path, ["commit", "-m", "candidate"])
    candidate_commit = git!(lease.worktree_path, ["rev-parse", "HEAD"])

    assert {:ok, published} =
             Workspace.Release.run(
               %{workspace_id: lease.workspace_id, mode: mode, commit_hash: candidate_commit},
               context
             )

    candidate = %{
      "task_id" => context.task_id,
      "principal_id" => context.principal_id,
      "workspace_id" => lease.workspace_id,
      "repo_path" => repo,
      "branch" => branch,
      "base_commit" => lease.base_commit,
      "candidate_commit" => candidate_commit,
      "branch_provenance" => provenance,
      "evidence_ref" => published.evidence_ref
    }

    %{
      repo: repo,
      branch: branch,
      destination_ref: destination_ref,
      candidate_commit: candidate_commit,
      worktree_path: lease.worktree_path,
      candidate: candidate
    }
  end

  defp commit_tree(repo, parent, message) do
    tree = git!(repo, ["rev-parse", "#{parent}^{tree}"])
    git!(repo, ["commit-tree", tree, "-p", parent, "-m", message])
  end

  defp branch_exists?(repo, branch) do
    {_output, status} =
      System.cmd("git", ["-C", repo, "show-ref", "--verify", "--quiet", "refs/heads/#{branch}"],
        stderr_to_stdout: true
      )

    status == 0
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
