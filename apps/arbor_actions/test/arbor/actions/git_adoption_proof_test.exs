defmodule Arbor.Actions.GitAdoptionProofTest do
  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions.Git

  setup_all do
    case Process.whereis(Arbor.Shell.ExecutionRegistry) do
      nil ->
        {:ok, _} = Application.ensure_all_started(:arbor_shell)

      _pid ->
        :ok
    end

    :ok
  end

  test "proves exact ancestry and verifies the unchanged proof", %{tmp_dir: tmp_dir} do
    repo = new_repo(tmp_dir)
    base = git_oid!(repo, ["rev-parse", "HEAD"])
    candidate = commit!(repo, "candidate.txt", "candidate\n", "candidate")

    assert {:ok, proof} = Git.compute_adoption_proof(repo, base, candidate, "main")
    assert proof["method"] == "ancestry"
    assert proof["base_commit"] == base
    assert proof["candidate_commit"] == candidate
    assert proof["destination_ref"] == "refs/heads/main"
    assert proof["destination_commit"] == candidate
    assert proof["candidate_commit_count"] == 1
    assert {:ok, _encoded} = Jason.encode(proof)
    assert :ok = Git.verify_adoption_proof(repo, proof)
  end

  test "proves a multi-commit cherry-pick", %{tmp_dir: tmp_dir} do
    repo = new_repo(tmp_dir)
    base = git_oid!(repo, ["rev-parse", "HEAD"])
    git!(repo, ["branch", "candidate"])
    git!(repo, ["branch", "destination"])

    git!(repo, ["checkout", "candidate"])
    first = commit!(repo, "first.txt", "first\n", "first")
    second = commit!(repo, "second.txt", "second\n", "second")
    git!(repo, ["checkout", "destination"])
    commit!(repo, "preexisting.txt", "preexisting\n", "preexisting")
    git!(repo, ["cherry-pick", "--no-ff", first, second])
    candidate = git_oid!(repo, ["rev-parse", "candidate"])

    assert {:ok, proof} = Git.compute_adoption_proof(repo, base, candidate, "destination")

    assert proof["method"] == "patch_equivalence"
    assert proof["audit"]["representation"] == "cherry_pick"
    assert proof["candidate_commit_count"] == 2
    assert length(proof["audit"]["candidate_patches"]) == 2
    assert Enum.map(proof["audit"]["candidate_patches"], & &1["commit"]) == [first, second]
    assert :ok = Git.verify_adoption_proof(repo, proof)
  end

  test "proves a multi-commit squash", %{tmp_dir: tmp_dir} do
    repo = new_repo(tmp_dir)
    base = git_oid!(repo, ["rev-parse", "HEAD"])
    git!(repo, ["branch", "candidate"])
    git!(repo, ["branch", "destination"])

    git!(repo, ["checkout", "candidate"])
    commit!(repo, "first.txt", "first\n", "first")
    commit!(repo, "second.txt", "second\n", "second")
    candidate = git_oid!(repo, ["rev-parse", "candidate"])
    git!(repo, ["checkout", "destination"])
    git!(repo, ["merge", "--squash", "candidate"])
    git!(repo, ["commit", "-m", "squashed candidate"])

    assert {:ok, proof} = Git.compute_adoption_proof(repo, base, candidate, "destination")
    assert proof["method"] == "patch_equivalence"
    assert proof["audit"]["representation"] == "squash"
    assert proof["audit"]["aggregate_destination"]["commit"] != nil
    assert :ok = Git.verify_adoption_proof(repo, proof)
  end

  test "completes adoption proof within the existing deadline for a large destination history", %{
    tmp_dir: tmp_dir
  } do
    repo = new_repo(tmp_dir)
    base = git_oid!(repo, ["rev-parse", "HEAD"])
    git!(repo, ["branch", "candidate"])
    git!(repo, ["branch", "destination"])

    git!(repo, ["checkout", "candidate"])
    first = commit!(repo, "first.txt", "first\n", "first")
    second = commit!(repo, "second.txt", "second\n", "second")
    candidate = git_oid!(repo, ["rev-parse", "candidate"])

    git!(repo, ["checkout", "destination"])

    for index <- 1..184 do
      git!(repo, ["commit", "--allow-empty", "-m", "destination-#{index}"])
    end

    git!(repo, ["cherry-pick", first, second])

    assert {:ok, proof} = Git.compute_adoption_proof(repo, base, candidate, "destination")
    assert proof["method"] == "patch_equivalence"
    assert proof["audit"]["representation"] == "cherry_pick"
    assert proof["candidate_commit_count"] == 2
    assert length(proof["audit"]["destination_patches"]) == 2
    assert :ok = Git.verify_adoption_proof(repo, proof)
  end

  test "rejects partial patch representation", %{tmp_dir: tmp_dir} do
    repo = new_repo(tmp_dir)
    base = git_oid!(repo, ["rev-parse", "HEAD"])
    git!(repo, ["branch", "candidate"])
    git!(repo, ["branch", "destination"])

    git!(repo, ["checkout", "candidate"])
    first = commit!(repo, "first.txt", "first\n", "first")
    commit!(repo, "second.txt", "second\n", "second")
    candidate = git_oid!(repo, ["rev-parse", "candidate"])
    git!(repo, ["checkout", "destination"])
    git!(repo, ["cherry-pick", first])

    assert {:error, {:not_adopted, _reason}} =
             Git.compute_adoption_proof(repo, base, candidate, "destination")
  end

  test "rejects an empty candidate commit in patch evidence", %{tmp_dir: tmp_dir} do
    repo = new_repo(tmp_dir)
    base = git_oid!(repo, ["rev-parse", "HEAD"])
    git!(repo, ["checkout", "-b", "candidate"])
    git!(repo, ["commit", "--allow-empty", "-m", "empty-candidate"])
    candidate = git_oid!(repo, ["rev-parse", "HEAD"])
    git!(repo, ["checkout", "main"])

    assert {:error, {:not_adopted, :candidate_contains_empty_commit}} =
             Git.compute_adoption_proof(repo, base, candidate, "main")
  end

  test "rejects a merge-containing candidate patch proof", %{tmp_dir: tmp_dir} do
    repo = new_repo(tmp_dir)
    base = git_oid!(repo, ["rev-parse", "HEAD"])
    git!(repo, ["branch", "candidate"])
    git!(repo, ["branch", "side"])
    git!(repo, ["branch", "destination"])

    git!(repo, ["checkout", "side"])
    commit!(repo, "side.txt", "side\n", "side")
    git!(repo, ["checkout", "candidate"])
    commit!(repo, "candidate.txt", "candidate\n", "candidate")
    git!(repo, ["merge", "--no-ff", "side", "-m", "merge candidate"])
    candidate = git_oid!(repo, ["rev-parse", "candidate"])

    git!(repo, ["checkout", "destination"])
    git!(repo, ["merge", "--squash", "candidate"])
    git!(repo, ["commit", "-m", "squashed merge candidate"])

    assert {:error, {:not_adopted, :candidate_range_contains_merge}} =
             Git.compute_adoption_proof(repo, base, candidate, "destination")
  end

  test "invalidates a proof when the destination ref moves", %{tmp_dir: tmp_dir} do
    repo = new_repo(tmp_dir)
    base = git_oid!(repo, ["rev-parse", "HEAD"])
    candidate = commit!(repo, "candidate.txt", "candidate\n", "candidate")

    assert {:ok, proof} = Git.compute_adoption_proof(repo, base, candidate, "main")
    commit!(repo, "later.txt", "later\n", "later")

    assert {:error, {:not_adopted, :proof_mismatch}} = Git.verify_adoption_proof(repo, proof)
  end

  test "rejects invalid destination refs and revision expressions", %{tmp_dir: tmp_dir} do
    repo = new_repo(tmp_dir)
    base = git_oid!(repo, ["rev-parse", "HEAD"])
    candidate = commit!(repo, "candidate.txt", "candidate\n", "candidate")

    assert {:error, {:invalid_input, :destination_revision_expression}} =
             Git.compute_adoption_proof(repo, base, candidate, "main~1")

    assert {:error, {:invalid_input, :destination_ref_not_found}} =
             Git.compute_adoption_proof(repo, base, candidate, "missing-ref")
  end

  test "rejects a candidate range above the conservative bound", %{tmp_dir: tmp_dir} do
    repo = new_repo(tmp_dir)
    base = git_oid!(repo, ["rev-parse", "HEAD"])
    git!(repo, ["checkout", "-b", "candidate"])

    for index <- 1..257 do
      git!(repo, ["commit", "--allow-empty", "-m", "candidate-#{index}"])
    end

    candidate = git_oid!(repo, ["rev-parse", "HEAD"])
    git!(repo, ["checkout", "main"])

    assert {:error, {:range_too_large, :candidate, 256}} =
             Git.compute_adoption_proof(repo, base, candidate, "main")
  end

  test "exact ancestry is not rejected by the patch fallback destination bound", %{
    tmp_dir: tmp_dir
  } do
    repo = new_repo(tmp_dir)
    base = git_oid!(repo, ["rev-parse", "HEAD"])
    candidate = commit!(repo, "candidate.txt", "candidate\n", "candidate")

    for index <- 1..257 do
      git!(repo, ["commit", "--allow-empty", "-m", "destination-#{index}"])
    end

    assert {:ok, proof} = Git.compute_adoption_proof(repo, base, candidate, "main")
    assert proof["method"] == "ancestry"
    assert proof["destination_commit"] == git_oid!(repo, ["rev-parse", "main"])
  end

  test "supports SHA-256 repositories when Git supports them", %{tmp_dir: tmp_dir} do
    repo = Path.join(tmp_dir, "sha256-repo")

    case System.cmd("git", ["init", "--object-format=sha256", repo], stderr_to_stdout: true) do
      {_output, 0} ->
        git!(repo, ["config", "user.email", "test@example.com"])
        git!(repo, ["config", "user.name", "Test User"])
        create_file(repo, "README.md", "# SHA-256\n")
        git!(repo, ["add", "README.md"])
        git!(repo, ["commit", "-m", "initial"])
        base = git_oid!(repo, ["rev-parse", "HEAD"])
        candidate = commit!(repo, "candidate.txt", "candidate\n", "candidate")

        assert byte_size(base) == 64
        assert byte_size(candidate) == 64
        assert {:ok, proof} = Git.compute_adoption_proof(repo, base, candidate, "HEAD")
        assert proof["method"] == "ancestry"
        assert :ok = Git.verify_adoption_proof(repo, proof)

      {_output, _exit_code} ->
        :ok
    end
  end

  defp new_repo(tmp_dir) do
    repo = Path.join(tmp_dir, "repo-#{System.unique_integer([:positive])}")
    create_git_repo(repo)
    git!(repo, ["branch", "-M", "main"])
    repo
  end

  defp commit!(repo, file, contents, message) do
    create_file(repo, file, contents)
    git!(repo, ["add", "--", file])
    git!(repo, ["commit", "-m", message])
    git_oid!(repo, ["rev-parse", "HEAD"])
  end

  defp git_oid!(repo, args), do: git!(repo, args) |> String.trim()

  defp git!(repo, args) do
    case System.cmd("git", args, cd: repo, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, exit_code} -> flunk("git #{inspect(args)} exited #{exit_code}: #{output}")
    end
  end
end
