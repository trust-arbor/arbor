defmodule Arbor.Actions.Coding.AdoptionTest do
  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions.Coding.Adoption
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Git

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

  test "invocation-created immutable candidate retires only a branch still at base", %{
    tmp_dir: tmp_dir
  } do
    fixture = immutable_published_candidate(tmp_dir, "created")
    git!(fixture.repo, ["update-ref", fixture.destination_ref, fixture.candidate_commit])

    assert {:ok, proof} = Adoption.prove(fixture.candidate, fixture.destination_ref)
    assert {:ok, settlement} = Adoption.settle(fixture.candidate, proof)
    assert settlement["status"] == "adopted"
    assert settlement["branch_retired"] == true
    refute branch_exists?(fixture.repo, fixture.branch)

    assert git!(fixture.repo, ["rev-parse", fixture.candidate["evidence_ref"]]) ==
             fixture.candidate_commit

    assert {:ok, replay} = Adoption.settle(fixture.candidate, proof)
    assert replay["branch_retired"] == true
  end

  test "immutable adoption preserves changed, reused, and unknown branches", %{tmp_dir: tmp_dir} do
    changed = immutable_published_candidate(tmp_dir, "created")
    git!(changed.repo, ["update-ref", changed.destination_ref, changed.candidate_commit])
    moved_tip = commit_tree(changed.repo, changed.candidate_commit, "moved branch")
    git!(changed.repo, ["update-ref", "refs/heads/#{changed.branch}", moved_tip])

    assert {:ok, proof} = Adoption.prove(changed.candidate, changed.destination_ref)
    assert {:ok, settlement} = Adoption.settle(changed.candidate, proof)
    assert settlement["branch_retired"] == false
    assert settlement["branch_preserved_reason"] == "branch_tip_changed"
    assert git!(changed.repo, ["rev-parse", "refs/heads/#{changed.branch}"]) == moved_tip

    reused = immutable_published_candidate(tmp_dir, "reused")
    git!(reused.repo, ["update-ref", reused.destination_ref, reused.candidate_commit])
    assert {:ok, proof} = Adoption.prove(reused.candidate, reused.destination_ref)
    assert {:ok, settlement} = Adoption.settle(reused.candidate, proof)
    assert settlement["branch_retired"] == false
    assert settlement["branch_preserved_reason"] == "reused_branch"
    assert branch_exists?(reused.repo, reused.branch)

    unknown = immutable_published_candidate(tmp_dir, "created")
    git!(unknown.repo, ["update-ref", unknown.destination_ref, unknown.candidate_commit])
    unknown_candidate = Map.put(unknown.candidate, "branch_provenance", "unknown")
    assert {:ok, proof} = Adoption.prove(unknown_candidate, unknown.destination_ref)
    assert {:ok, settlement} = Adoption.settle(unknown_candidate, proof)
    assert settlement["branch_retired"] == false
    assert settlement["branch_preserved_reason"] == "unknown_branch_provenance"
    assert branch_exists?(unknown.repo, unknown.branch)
  end

  test "prove and settle reject mixed aliases and unknown source before legacy coercion", %{
    tmp_dir: tmp_dir
  } do
    fixture = immutable_published_candidate(tmp_dir, "created")
    git!(fixture.repo, ["update-ref", fixture.destination_ref, fixture.candidate_commit])
    assert {:ok, proof} = Adoption.prove(fixture.candidate, fixture.destination_ref)

    mixed =
      fixture.candidate
      |> Map.put(:candidate_source, "immutable_object")
      |> Map.put("candidate_source", "immutable_object")

    assert {:error, :ambiguous_candidate_source} =
             Adoption.prove(mixed, fixture.destination_ref)

    assert {:error, :ambiguous_candidate_source} = Adoption.settle(mixed, proof)

    invalid = Map.put(fixture.candidate, "candidate_source", "immutable")
    assert {:error, :invalid_candidate_source} = Adoption.prove(invalid, fixture.destination_ref)
    assert {:error, :invalid_candidate_source} = Adoption.settle(invalid, proof)
    assert branch_exists?(fixture.repo, fixture.branch)

    assert git!(fixture.repo, ["rev-parse", fixture.candidate["evidence_ref"]]) ==
             fixture.candidate_commit
  end

  test "legacy maps do not upgrade immutable-shaped candidates; created-at-candidate stays preserved",
       %{tmp_dir: tmp_dir} do
    fixture = immutable_published_candidate(tmp_dir, "created")
    git!(fixture.repo, ["update-ref", fixture.destination_ref, fixture.candidate_commit])
    legacy = Map.delete(fixture.candidate, "candidate_source")
    assert {:ok, proof} = Adoption.prove(legacy, fixture.destination_ref)

    assert {:error, :branch_ref_oid_mismatch} = Adoption.settle(legacy, proof)
    assert branch_exists?(fixture.repo, fixture.branch)

    explicit = Map.put(legacy, "candidate_source", "workspace_branch")
    assert {:ok, proof} = Adoption.prove(explicit, fixture.destination_ref)
    assert {:error, :branch_ref_oid_mismatch} = Adoption.settle(explicit, proof)
    assert branch_exists?(fixture.repo, fixture.branch)
    assert git!(fixture.repo, ["rev-parse", "refs/heads/#{fixture.branch}"]) == fixture.base_commit

    at_candidate = published_candidate(tmp_dir, "created", "publish")

    git!(
      at_candidate.repo,
      ["update-ref", at_candidate.destination_ref, at_candidate.candidate_commit]
    )

    immutable_on_legacy =
      Map.put(at_candidate.candidate, "candidate_source", "immutable_object")

    assert {:ok, proof} = Adoption.prove(immutable_on_legacy, at_candidate.destination_ref)
    assert {:ok, settlement} = Adoption.settle(immutable_on_legacy, proof)
    assert settlement["branch_retired"] == false
    assert settlement["branch_preserved_reason"] == "branch_tip_changed"
    assert branch_exists?(at_candidate.repo, at_candidate.branch)
  end

  defp immutable_published_candidate(tmp_dir, provenance) do
    unique = System.unique_integer([:positive])
    repo = create_git_repo(Path.join(tmp_dir, "imm_adopt_#{provenance}_#{unique}"))
    destination_ref = git!(repo, ["symbolic-ref", "HEAD"])
    branch = "test/imm-adoption-#{provenance}-#{unique}"

    context = %{
      task_id: "task_imm_adoption_#{provenance}_#{unique}",
      principal_id: "agent_adoption"
    }

    if provenance == "reused", do: git!(repo, ["branch", branch])

    assert {:ok, lease} =
             Workspace.Acquire.run(
               %{
                 repo_path: repo,
                 branch_name: branch,
                 worktree_base_dir: Path.join(tmp_dir, "imm_adopt_worktrees_#{unique}")
               },
               context
             )

    assert lease.branch_provenance == provenance

    {candidate_commit, _tree} =
      object_commit(repo, lease.base_commit, "candidate.txt", "candidate\n", tmp_dir)

    assert {:ok, %{hidden_ref: evidence_ref}} =
             Git.pin_task_workspace_commit(
               repo,
               context.task_id,
               lease.workspace_id,
               candidate_commit
             )

    assert {:ok, published} =
             Workspace.Release.run(
               %{
                 workspace_id: lease.workspace_id,
                 mode: "publish",
                 commit_hash: candidate_commit,
                 candidate_source: "immutable_object"
               },
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
      "evidence_ref" => published.evidence_ref,
      "candidate_source" => "immutable_object"
    }

    %{
      repo: repo,
      branch: branch,
      destination_ref: destination_ref,
      candidate_commit: candidate_commit,
      base_commit: lease.base_commit,
      worktree_path: lease.worktree_path,
      candidate: candidate,
      evidence_ref: evidence_ref
    }
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

  defp git_index!(repo, index, args) do
    {output, 0} =
      System.cmd("git", ["-C", repo | args],
        stderr_to_stdout: true,
        env: [{"GIT_INDEX_FILE", index}]
      )

    String.trim(output)
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
